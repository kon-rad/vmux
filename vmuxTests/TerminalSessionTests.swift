import XCTest
import SwiftTerm
@testable import vmux

@MainActor
final class TerminalSessionTests: XCTestCase {

    func testFeedBytesAppearInTerminalBuffer() async throws {
        let stub = StubTerminalShellChannel()
        let session = TerminalSession(
            tabID: UUID(),
            projectID: UUID(),
            channel: stub
        )

        let payload = "Hello, vmux!"
        stub.yield(Data(payload.utf8))

        try await waitFor(timeout: 1.0) { @MainActor in
            firstLineText(of: session.terminal).contains(payload)
        }

        let lastByteAt = session.lastByteAt
        XCTAssertGreaterThanOrEqual(lastByteAt.timeIntervalSinceNow, -1.0,
                                    "lastByteAt should be near 'now' after feeding bytes")

        await session.close()
    }

    func testSendWritesBytesToChannel() async throws {
        let stub = StubTerminalShellChannel()
        let session = TerminalSession(
            tabID: UUID(),
            projectID: UUID(),
            channel: stub
        )

        let payload = Data("pwd\n".utf8)
        session.send(payload)

        try await waitFor(timeout: 1.0) {
            await stub.writeCount() >= 1
        }

        let writes = await stub.writes()
        XCTAssertEqual(writes, [payload])

        await session.close()
    }

    func testCloseFinishesInboundStreamAndCancelsPump() async throws {
        let stub = StubTerminalShellChannel()
        let session = TerminalSession(
            tabID: UUID(),
            projectID: UUID(),
            channel: stub
        )

        stub.yield(Data("seed".utf8))
        try await waitFor(timeout: 1.0) { @MainActor in
            firstLineText(of: session.terminal).contains("seed")
        }

        await session.close()

        // Yielding after close should not throw and should be ignored by the pump.
        stub.yield(Data("post-close".utf8))
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(firstLineText(of: session.terminal).contains("post-close"),
                       "Pump should have stopped after close()")
    }

    // MARK: - Helpers

    private func firstLineText(of terminal: Terminal) -> String {
        var text = ""
        let (cols, _) = terminal.getDims()
        for col in 0..<cols {
            guard let ch = terminal.getCharacter(col: col, row: 0) else { break }
            if ch == "\0" { break }
            text.append(ch)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

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

// MARK: - Stub channel

final class StubTerminalShellChannel: TerminalShellChannel, @unchecked Sendable {
    let inbound: AsyncStream<Data>

    private let inboundCont: AsyncStream<Data>.Continuation
    private let recorder = WriteRecorder()

    init() {
        var capturedCont: AsyncStream<Data>.Continuation!
        self.inbound = AsyncStream<Data> { continuation in
            capturedCont = continuation
        }
        self.inboundCont = capturedCont
    }

    func yield(_ data: Data) {
        inboundCont.yield(data)
    }

    func send(_ data: Data) async throws {
        await recorder.record(data)
    }

    func close() async {
        inboundCont.finish()
    }

    func writes() async -> [Data] {
        await recorder.snapshot()
    }

    func writeCount() async -> Int {
        await recorder.snapshot().count
    }
}

private actor WriteRecorder {
    private var writes: [Data] = []

    func record(_ data: Data) {
        writes.append(data)
    }

    func snapshot() -> [Data] {
        writes
    }
}
