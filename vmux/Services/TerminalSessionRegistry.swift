import Foundation
import SwiftData

enum TerminalSessionRegistryError: Error, CustomStringConvertible {
    case projectNotResolvable
    case unknownTab

    var description: String {
        switch self {
        case .projectNotResolvable:
            return "Tab is not associated with a project."
        case .unknownTab:
            return "No session has ever been opened for this tab."
        }
    }
}

/// Holds one live `TerminalSession` per `Tab.id`. Closing the window does NOT
/// invoke `remove(tabID:)` — the session stays alive so reopening the window
/// continues from where the user left off. Sidebar tab deletion is the only
/// thing that calls `remove(tabID:)`.
@MainActor
final class TerminalSessionRegistry {
    static let shared = TerminalSessionRegistry()

    var sessions: [UUID: TerminalSession] = [:]
    private var inflight: [UUID: Task<TerminalSession, any Error>] = [:]
    private var monitors: [UUID: ActivityMonitor] = [:]
    /// Stable references to the `Tab` model used to construct each session, so
    /// `reconnect(tabID:)` (T-024) can rebuild without asking the caller for a
    /// fresh fetch. Cleared in `remove(tabID:)` alongside the live session.
    private var tabs: [UUID: Tab] = [:]
    private var disconnectHandlerInstalled = false

    private let connectionManager: SSHConnectionManager

    init(connectionManager: SSHConnectionManager = .shared) {
        self.connectionManager = connectionManager
    }

    func sessionIfExists(tabID: UUID) -> TerminalSession? {
        sessions[tabID]
    }

    /// Mark every session bound to this project as disconnected. Invoked by
    /// `SSHConnectionManager` when the underlying client closes (T-024).
    func handleProjectDisconnect(projectID: UUID, reason: String = "SSH connection closed.") {
        for (_, session) in sessions where session.projectID == projectID {
            session.setStatus(.disconnected(reason: reason))
        }
    }

    private func installDisconnectHandlerIfNeeded() async {
        if disconnectHandlerInstalled { return }
        disconnectHandlerInstalled = true
        await connectionManager.setOnProjectDisconnect { @Sendable [weak self] projectID in
            guard let self else { return }
            await MainActor.run {
                self.handleProjectDisconnect(projectID: projectID)
            }
        }
    }

    /// Returns the existing session for this tab, or creates one by opening a
    /// PTY-backed shell on the project's shared SSH client.
    func session(for tab: Tab) async throws -> TerminalSession {
        await installDisconnectHandlerIfNeeded()
        if let existing = sessions[tab.id] {
            tabs[tab.id] = tab
            return existing
        }
        if let pending = inflight[tab.id] {
            return try await pending.value
        }
        guard let project = tab.project else {
            throw TerminalSessionRegistryError.projectNotResolvable
        }
        tabs[tab.id] = tab
        let info = SSHProjectInfo(project: project)
        let tabID = tab.id
        let projectID = project.id
        let connectionManager = self.connectionManager
        let modelContext = tab.modelContext

        let task = Task<TerminalSession, any Error> {
            let client = try await connectionManager.client(for: info)
            let channel = try await CitadelShellChannel.connect(client: client)
            return await MainActor.run {
                TerminalSession(tabID: tabID, projectID: projectID, channel: channel)
            }
        }
        inflight[tab.id] = task
        do {
            let session = try await task.value
            sessions[tab.id] = session
            inflight[tab.id] = nil
            if let modelContext, monitors[tab.id] == nil {
                let monitor = ActivityMonitor(
                    tabID: tab.id,
                    session: session,
                    modelContext: modelContext,
                    idleThresholdProvider: { [modelContext] in
                        let descriptor = FetchDescriptor<AppSettings>()
                        let row = try? modelContext.fetch(descriptor).first
                        return TimeInterval(row?.idleThresholdSeconds ?? 3)
                    }
                )
                monitor.start()
                monitors[tab.id] = monitor
            }
            return session
        } catch {
            inflight[tab.id] = nil
            throw error
        }
    }

    /// Tear down a session and forget it. Called by sidebar tab deletion.
    func remove(tabID: UUID) async {
        tabs.removeValue(forKey: tabID)
        if let task = inflight.removeValue(forKey: tabID) {
            task.cancel()
        }
        if let monitor = monitors.removeValue(forKey: tabID) {
            monitor.stop()
        }
        guard let session = sessions.removeValue(forKey: tabID) else { return }
        await session.close()
    }

    /// Tear down the existing (dead) session for this tab and open a fresh one
    /// bound to the same `Tab`. Invoked by the disconnect banner's tap target
    /// in `TerminalWindowView` (T-024).
    func reconnect(tabID: UUID) async throws -> TerminalSession {
        if let task = inflight.removeValue(forKey: tabID) {
            task.cancel()
        }
        if let monitor = monitors.removeValue(forKey: tabID) {
            monitor.stop()
        }
        if let session = sessions.removeValue(forKey: tabID) {
            await session.close()
        }
        guard let tab = tabs[tabID] else {
            throw TerminalSessionRegistryError.unknownTab
        }
        return try await session(for: tab)
    }
}
