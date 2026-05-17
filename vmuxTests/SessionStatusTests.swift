import XCTest
@testable import vmux

/// T-024: `SessionStatus` transitions on `TerminalSession` and the registry's
/// disconnect-propagation path.
@MainActor
final class SessionStatusTests: XCTestCase {

    func testInitialStatusIsConnecting() {
        let stub = StubTerminalShellChannel()
        let session = TerminalSession(tabID: UUID(), projectID: UUID(), channel: stub)
        XCTAssertEqual(session.status, .connecting)
    }

    func testFirstInboundByteTransitionsToConnected() async throws {
        let stub = StubTerminalShellChannel()
        let session = TerminalSession(tabID: UUID(), projectID: UUID(), channel: stub)
        stub.yield(Data("hi".utf8))

        try await waitFor(timeout: 1.0) { @MainActor in
            session.status == .connected
        }

        await session.close()
    }

    func testInboundStreamEndingTransitionsToDisconnected() async throws {
        let stub = StubTerminalShellChannel()
        let session = TerminalSession(tabID: UUID(), projectID: UUID(), channel: stub)

        // Close the stub's inbound stream from the outside — simulates the SSH
        // channel ending without `session.close()` being called.
        await stub.close()

        try await waitFor(timeout: 1.0) { @MainActor in
            if case .disconnected = session.status { return true }
            return false
        }
    }

    func testManualCloseDoesNotTransitionToDisconnected() async throws {
        let stub = StubTerminalShellChannel()
        let session = TerminalSession(tabID: UUID(), projectID: UUID(), channel: stub)

        await session.close()
        // Status should remain `.connecting` — manual close is an
        // app-initiated teardown, not an unexpected disconnect.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(session.status, .connecting)
    }

    func testSetStatusExternalTransition() {
        let stub = StubTerminalShellChannel()
        let session = TerminalSession(tabID: UUID(), projectID: UUID(), channel: stub)
        session.setStatus(.disconnected(reason: "test"))
        XCTAssertEqual(session.status, .disconnected(reason: "test"))
    }

    func testRegistryDisconnectFlipsMatchingProjectsOnly() {
        let registry = TerminalSessionRegistry()
        let projectA = UUID()
        let projectB = UUID()

        let a1 = TerminalSession(
            tabID: UUID(), projectID: projectA, channel: StubTerminalShellChannel()
        )
        let a2 = TerminalSession(
            tabID: UUID(), projectID: projectA, channel: StubTerminalShellChannel()
        )
        let b1 = TerminalSession(
            tabID: UUID(), projectID: projectB, channel: StubTerminalShellChannel()
        )

        registry.sessions[a1.tabID] = a1
        registry.sessions[a2.tabID] = a2
        registry.sessions[b1.tabID] = b1

        registry.handleProjectDisconnect(projectID: projectA, reason: "server gone")

        XCTAssertEqual(a1.status, .disconnected(reason: "server gone"))
        XCTAssertEqual(a2.status, .disconnected(reason: "server gone"))
        XCTAssertEqual(b1.status, .connecting,
                       "Project B's session must not be touched by Project A's disconnect")
    }

    // MARK: - Helpers

    private func waitFor(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.02,
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
