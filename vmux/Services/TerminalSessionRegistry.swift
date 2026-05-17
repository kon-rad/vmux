import Foundation

enum TerminalSessionRegistryError: Error, CustomStringConvertible {
    case projectNotResolvable

    var description: String {
        switch self {
        case .projectNotResolvable:
            return "Tab is not associated with a project."
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

    private var sessions: [UUID: TerminalSession] = [:]
    private var inflight: [UUID: Task<TerminalSession, any Error>] = [:]

    private let connectionManager: SSHConnectionManager

    init(connectionManager: SSHConnectionManager = .shared) {
        self.connectionManager = connectionManager
    }

    func sessionIfExists(tabID: UUID) -> TerminalSession? {
        sessions[tabID]
    }

    /// Returns the existing session for this tab, or creates one by opening a
    /// PTY-backed shell on the project's shared SSH client.
    func session(for tab: Tab) async throws -> TerminalSession {
        if let existing = sessions[tab.id] {
            return existing
        }
        if let pending = inflight[tab.id] {
            return try await pending.value
        }
        guard let project = tab.project else {
            throw TerminalSessionRegistryError.projectNotResolvable
        }
        let info = SSHProjectInfo(project: project)
        let tabID = tab.id
        let projectID = project.id
        let connectionManager = self.connectionManager

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
            return session
        } catch {
            inflight[tab.id] = nil
            throw error
        }
    }

    /// Tear down a session and forget it. Called by sidebar tab deletion.
    func remove(tabID: UUID) async {
        if let task = inflight.removeValue(forKey: tabID) {
            task.cancel()
        }
        guard let session = sessions.removeValue(forKey: tabID) else { return }
        await session.close()
    }
}
