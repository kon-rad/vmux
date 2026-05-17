import XCTest
import SwiftData
@testable import vmux

@MainActor
final class ActivityMonitorTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: Project.self, vmux.Tab.self, AppSettings.self,
            configurations: config
        )
    }

    private func waitForLastByteAtChange(
        session: TerminalSession,
        from baseline: Date,
        timeout: TimeInterval = 1.0
    ) async throws {
        try await waitFor(timeout: timeout) { @MainActor in
            session.lastByteAt != baseline
        }
    }

    func testActivityFlipsIsRunningAndUpdatesLastActivityAt() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(AppSettings(idleThresholdSeconds: 1))
        let tab = vmux.Tab(title: "T")
        context.insert(tab)
        try context.save()

        let stub = StubTerminalShellChannel()
        let session = TerminalSession(tabID: tab.id, projectID: UUID(), channel: stub)

        var simulatedNow = Date()
        var doneCount = 0
        let monitor = ActivityMonitor(
            tabID: tab.id,
            session: session,
            modelContext: context,
            idleThresholdProvider: { 1.0 },
            nowProvider: { simulatedNow },
            onDone: { doneCount += 1 }
        )

        // Baseline tick: nothing should change.
        monitor.tick()
        XCTAssertFalse(tab.isRunning)
        XCTAssertEqual(doneCount, 0)

        // Bytes arrive — wait for session.lastByteAt to actually advance past
        // its initial value before driving the monitor.
        let initialByteAt = session.lastByteAt
        stub.yield(Data("output".utf8))
        try await waitForLastByteAtChange(session: session, from: initialByteAt)
        let activityTimestamp = session.lastByteAt

        monitor.tick()
        XCTAssertTrue(tab.isRunning)
        XCTAssertEqual(
            tab.lastActivityAt.timeIntervalSinceReferenceDate,
            activityTimestamp.timeIntervalSinceReferenceDate,
            accuracy: 0.001
        )
        XCTAssertEqual(doneCount, 0)

        // Advance the clock past the idle threshold — should fire done once.
        simulatedNow = activityTimestamp.addingTimeInterval(1.5)
        monitor.tick()
        XCTAssertFalse(tab.isRunning)
        XCTAssertEqual(doneCount, 1)

        // Idle stays idle — done should not fire again.
        simulatedNow = activityTimestamp.addingTimeInterval(3.0)
        monitor.tick()
        XCTAssertFalse(tab.isRunning)
        XCTAssertEqual(doneCount, 1)

        await session.close()
        monitor.stop()
    }

    func testRecurrentDoneAfterReactivation() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(AppSettings(idleThresholdSeconds: 1))
        let tab = vmux.Tab(title: "T")
        context.insert(tab)
        try context.save()

        let stub = StubTerminalShellChannel()
        let session = TerminalSession(tabID: tab.id, projectID: UUID(), channel: stub)

        var simulatedNow = Date()
        var doneCount = 0
        let monitor = ActivityMonitor(
            tabID: tab.id,
            session: session,
            modelContext: context,
            idleThresholdProvider: { 1.0 },
            nowProvider: { simulatedNow },
            onDone: { doneCount += 1 }
        )

        // First run cycle.
        var baseline = session.lastByteAt
        stub.yield(Data("one".utf8))
        try await waitForLastByteAtChange(session: session, from: baseline)
        monitor.tick()
        XCTAssertTrue(tab.isRunning)

        simulatedNow = session.lastByteAt.addingTimeInterval(1.5)
        monitor.tick()
        XCTAssertFalse(tab.isRunning)
        XCTAssertEqual(doneCount, 1)

        // Second run cycle should fire done again.
        baseline = session.lastByteAt
        stub.yield(Data("two".utf8))
        try await waitForLastByteAtChange(session: session, from: baseline)
        monitor.tick()
        XCTAssertTrue(tab.isRunning)

        simulatedNow = session.lastByteAt.addingTimeInterval(1.5)
        monitor.tick()
        XCTAssertFalse(tab.isRunning)
        XCTAssertEqual(doneCount, 2)

        await session.close()
        monitor.stop()
    }

    func testStartTimerEventuallyFires() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(AppSettings(idleThresholdSeconds: 1))
        let tab = vmux.Tab(title: "T")
        context.insert(tab)
        try context.save()

        let stub = StubTerminalShellChannel()
        let session = TerminalSession(tabID: tab.id, projectID: UUID(), channel: stub)

        let monitor = ActivityMonitor(
            tabID: tab.id,
            session: session,
            modelContext: context,
            idleThresholdProvider: { 0.5 },
            onDone: { }
        )
        monitor.start()

        stub.yield(Data("hello".utf8))

        // 500ms timer + 500ms idle threshold → expect isRunning to bounce
        // true then back to false within ~2s.
        try await waitFor(timeout: 3.0) { @MainActor in tab.isRunning }
        try await waitFor(timeout: 3.0) { @MainActor in !tab.isRunning }

        await session.close()
        monitor.stop()
    }

    private func waitFor(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.05,
        _ predicate: () async -> Bool,
        file: StaticString = #file,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        XCTFail("waitFor timed out after \(timeout)s", file: file, line: line)
    }
}
