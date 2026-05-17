import XCTest
@testable import vmux

final class GeminiLiveSessionTests: XCTestCase {
    func test_start_sendsCorrectSetupMessage_andResolvesOnSetupComplete() async throws {
        let stub = StubGeminiChannel()
        let session = GeminiLiveSession(
            apiKey: "TEST_KEY",
            model: "gemini-2.5-flash",
            channelFactory: { _ in stub }
        )

        let startTask = Task { try await session.start() }

        let setupBody = try await stub.nextSent(timeout: 1.0)
        await stub.push(.text("{\"setupComplete\":{}}"))
        try await startTask.value

        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(setupBody.utf8)) as? [String: Any],
            "Setup message must be valid JSON"
        )
        let config = try XCTUnwrap(parsed["config"] as? [String: Any])
        XCTAssertEqual(config["model"] as? String, "models/gemini-2.5-flash")
        XCTAssertEqual(config["responseModalities"] as? [String], ["TEXT"])
        XCTAssertNotNil(
            config["inputAudioTranscription"] as? [String: Any],
            "inputAudioTranscription must be present as an empty object"
        )
        let sysInstr = try XCTUnwrap(config["systemInstruction"] as? [String: Any])
        let parts = try XCTUnwrap(sysInstr["parts"] as? [[String: Any]])
        XCTAssertEqual(
            parts.first?["text"] as? String,
            "Transcribe the user's spoken words verbatim. Do not respond. Do not paraphrase. Output exactly what was said."
        )

        XCTAssertTrue(stub.didResume)
        await session.close()
    }

    func test_inputTranscriptionFrame_yieldsPartialEvents_inOrder() async throws {
        let stub = StubGeminiChannel()
        let session = GeminiLiveSession(
            apiKey: "K",
            model: "gemini-2.5-flash",
            channelFactory: { _ in stub }
        )

        let startTask = Task { try await session.start() }
        _ = try await stub.nextSent(timeout: 1.0)
        await stub.push(.text("{\"setupComplete\":{}}"))
        try await startTask.value

        let collector = Task { () -> [TranscriptEvent] in
            var collected: [TranscriptEvent] = []
            for await event in session.events {
                collected.append(event)
                if collected.count == 2 { break }
            }
            return collected
        }

        await stub.push(.text("{\"serverContent\":{\"inputTranscription\":{\"text\":\"hello\"}}}"))
        await stub.push(.text("{\"serverContent\":{\"inputTranscription\":{\"text\":\" world\"}}}"))

        let events = await collector.value
        XCTAssertEqual(events, [.partial("hello"), .partial(" world")])

        await session.close()
    }

    func test_sendAudio_basesIntoRealtimeInputAudioFrame() async throws {
        let stub = StubGeminiChannel()
        let session = GeminiLiveSession(
            apiKey: "K",
            model: "gemini-2.5-flash",
            channelFactory: { _ in stub }
        )

        let startTask = Task { try await session.start() }
        _ = try await stub.nextSent(timeout: 1.0)
        await stub.push(.text("{\"setupComplete\":{}}"))
        try await startTask.value

        let pcm = Data([0x01, 0x02, 0x03, 0x04, 0xFF, 0x00])
        try await session.sendAudio(pcm)

        let frame = try await stub.nextSent(timeout: 1.0)
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any]
        )
        let realtimeInput = try XCTUnwrap(parsed["realtimeInput"] as? [String: Any])
        let audio = try XCTUnwrap(realtimeInput["audio"] as? [String: Any])
        XCTAssertEqual(audio["data"] as? String, pcm.base64EncodedString())
        XCTAssertEqual(audio["mimeType"] as? String, "audio/pcm;rate=16000")

        await session.close()
    }

    func test_close_finishesEventsStream_andCancelsChannel() async throws {
        let stub = StubGeminiChannel()
        let session = GeminiLiveSession(
            apiKey: "K",
            model: "gemini-2.5-flash",
            channelFactory: { _ in stub }
        )

        let startTask = Task { try await session.start() }
        _ = try await stub.nextSent(timeout: 1.0)
        await stub.push(.text("{\"setupComplete\":{}}"))
        try await startTask.value

        let streamDrained = Task { () -> Int in
            var count = 0
            for await _ in session.events { count += 1 }
            return count
        }

        await session.close()
        let count = await streamDrained.value
        XCTAssertEqual(count, 0)
        XCTAssertTrue(stub.didCancel)
    }

    func test_buildURL_putsKeyInQueryString() {
        let url = GeminiLiveSession.buildURL(apiKey: "abc 123")
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "generativelanguage.googleapis.com")
        XCTAssertEqual(
            url.path,
            "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        )
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.queryItems?.first?.name, "key")
        XCTAssertEqual(components?.queryItems?.first?.value, "abc 123")
    }
}

// MARK: - Stub channel

/// In-process stand-in for `URLSessionWebSocketTask`. Records outbound frames,
/// lets tests push inbound frames, and serializes access via an internal actor
/// so concurrent `send`/`receive` from the production code is safe.
final class StubGeminiChannel: GeminiWebSocketChannel, @unchecked Sendable {
    private let mailbox = ChannelMailbox()

    private(set) var didResume = false
    private(set) var didCancel = false
    private let resumeLock = NSLock()

    func resume() {
        resumeLock.lock()
        didResume = true
        resumeLock.unlock()
    }

    func send(text: String) async throws {
        await mailbox.recordSent(text)
    }

    func receive() async throws -> WebSocketIncoming {
        if let msg = await mailbox.nextIncoming() {
            return msg
        }
        throw CancellationError()
    }

    func cancel(code: Int, reason: Data?) {
        resumeLock.lock()
        didCancel = true
        resumeLock.unlock()
        Task { await mailbox.closeIncoming() }
    }

    func push(_ msg: WebSocketIncoming) async {
        await mailbox.pushIncoming(msg)
    }

    func nextSent(timeout: TimeInterval) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let s = await mailbox.popSent() {
                return s
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw XCTSkip("Stub did not receive a sent frame within \(timeout)s")
    }
}

private actor ChannelMailbox {
    private var sent: [String] = []
    private var incoming: [WebSocketIncoming] = []
    private var waiters: [CheckedContinuation<WebSocketIncoming?, Never>] = []
    private var incomingClosed = false

    func recordSent(_ s: String) {
        sent.append(s)
    }

    func popSent() -> String? {
        guard !sent.isEmpty else { return nil }
        return sent.removeFirst()
    }

    func pushIncoming(_ msg: WebSocketIncoming) {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: msg)
        } else {
            incoming.append(msg)
        }
    }

    func nextIncoming() async -> WebSocketIncoming? {
        if !incoming.isEmpty {
            return incoming.removeFirst()
        }
        if incomingClosed {
            return nil
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<WebSocketIncoming?, Never>) in
            waiters.append(cont)
        }
    }

    func closeIncoming() {
        incomingClosed = true
        let pending = waiters
        waiters.removeAll()
        for w in pending {
            w.resume(returning: nil)
        }
    }
}
