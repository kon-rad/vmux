import Foundation
import AudioToolbox
import SwiftData

/// Watches one `TerminalSession`'s `lastByteAt` clock and flips its `Tab`
/// between running and idle. Drives the sidebar's status dot (T-014) and fires
/// the "agent done" system sound when an idle threshold elapses after activity.
///
/// Lifecycle is owned by `TerminalSessionRegistry`: a monitor is created when a
/// session is created, and stopped when the session is torn down. The 500ms
/// timer polls the session — we don't observe `lastByteAt` directly because
/// `tab.lastActivityAt` must mirror it on each change anyway.
@MainActor
final class ActivityMonitor {
    private let tabID: UUID
    private weak var session: TerminalSession?
    private let modelContext: ModelContext
    private let idleThresholdProvider: @MainActor () -> TimeInterval
    private let nowProvider: @MainActor () -> Date
    private let onDone: @MainActor () -> Void

    private var timer: Timer?
    private var lastSeenByteAt: Date

    init(
        tabID: UUID,
        session: TerminalSession,
        modelContext: ModelContext,
        idleThresholdProvider: @escaping @MainActor () -> TimeInterval,
        nowProvider: @escaping @MainActor () -> Date = { Date() },
        onDone: @escaping @MainActor () -> Void = { AudioServicesPlaySystemSound(1004) }
    ) {
        self.tabID = tabID
        self.session = session
        self.modelContext = modelContext
        self.idleThresholdProvider = idleThresholdProvider
        self.nowProvider = nowProvider
        self.onDone = onDone
        // Seed with the session's current value so the initial timestamp
        // assigned in `TerminalSession.init` is not mistaken for fresh activity.
        self.lastSeenByteAt = session.lastByteAt
    }

    func start() {
        stop()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Internal so tests can drive the state machine deterministically without
    /// waiting on a wall-clock timer.
    func tick() {
        guard let session, let tab = lookupTab() else { return }
        let lastByteAt = session.lastByteAt

        if lastByteAt != lastSeenByteAt {
            lastSeenByteAt = lastByteAt
            tab.isRunning = true
            tab.lastActivityAt = lastByteAt
            try? modelContext.save()
            return
        }

        if tab.isRunning,
           nowProvider().timeIntervalSince(lastByteAt) > idleThresholdProvider() {
            tab.isRunning = false
            try? modelContext.save()
            onDone()
        }
    }

    private func lookupTab() -> Tab? {
        let id = tabID
        var descriptor = FetchDescriptor<Tab>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }
}
