import Foundation

/// Events emitted by `GeminiLiveSession.events` as the server returns
/// `serverContent.inputTranscription` frames. Gemini streams incremental
/// fragments (not cumulative strings), so consumers should append.
enum TranscriptEvent: Equatable, Sendable {
    case partial(String)
}

enum GeminiLiveError: Error, Equatable, Sendable, CustomStringConvertible {
    case alreadyClosed
    case alreadyStarted
    case setupFailed(String)
    case maxReconnectAttemptsReached

    var description: String {
        switch self {
        case .alreadyClosed:
            return "Gemini Live session has been closed."
        case .alreadyStarted:
            return "Gemini Live session has already been started."
        case .setupFailed(let detail):
            return "Gemini Live setup failed: \(detail)"
        case .maxReconnectAttemptsReached:
            return "Gemini Live exceeded maximum reconnect attempts."
        }
    }
}

/// Incoming WebSocket message variants. Mirrors the subset of
/// `URLSessionWebSocketTask.Message` we care about, while staying Sendable
/// for use across actor boundaries (and for the test stub).
enum WebSocketIncoming: Sendable, Equatable {
    case text(String)
    case data(Data)
}

/// Production implementations wrap `URLSessionWebSocketTask`; the test
/// suite supplies a stub. The protocol is Sendable so it can be injected
/// from outside the actor and held across suspension points.
protocol GeminiWebSocketChannel: Sendable {
    func resume()
    func send(text: String) async throws
    func receive() async throws -> WebSocketIncoming
    func cancel(code: Int, reason: Data?)
}

/// Actor that owns a single bidirectional WebSocket to Gemini's Live API and
/// exposes (a) a stream of transcript fragments, (b) an `async sendAudio`
/// entry point for PCM16 audio frames, and (c) a `close()` to tear down.
///
/// Lifecycle: construct, call `start()` to open the WebSocket and wait for
/// `setupComplete`, then call `sendAudio(_:)` as buffers arrive. On unexpected
/// disconnect the receive loop schedules a reconnect with exponential backoff
/// (250 ms → 4 s, capped at 5 attempts) and re-sends the setup message.
actor GeminiLiveSession {
    let apiKey: String
    let model: String

    /// Stream of transcription events. Safe to read from any isolation domain
    /// before `start()` because the underlying `AsyncStream` is `Sendable` and
    /// buffers events until consumed.
    nonisolated let events: AsyncStream<TranscriptEvent>
    private nonisolated let eventsContinuation: AsyncStream<TranscriptEvent>.Continuation

    private let channelFactory: @Sendable (URL) -> any GeminiWebSocketChannel
    private var channel: (any GeminiWebSocketChannel)?
    private var receiveTask: Task<Void, Never>?
    private var setupContinuation: CheckedContinuation<Void, Error>?

    private var isReady = false
    private var isClosed = false
    private var hasStarted = false
    private var reconnectAttempts = 0

    private static let initialReconnectDelay: TimeInterval = 0.25
    private static let maxReconnectDelay: TimeInterval = 4.0
    private static let maxReconnectAttempts = 5

    init(
        apiKey: String,
        model: String,
        channelFactory: (@Sendable (URL) -> any GeminiWebSocketChannel)? = nil
    ) {
        self.apiKey = apiKey
        self.model = model
        self.channelFactory = channelFactory ?? URLSessionGeminiChannel.defaultFactory

        var capturedContinuation: AsyncStream<TranscriptEvent>.Continuation!
        self.events = AsyncStream<TranscriptEvent> { continuation in
            capturedContinuation = continuation
        }
        self.eventsContinuation = capturedContinuation
    }

    /// Opens the WebSocket, sends the setup message, and suspends until the
    /// server's `setupComplete` frame arrives. Throws if setup fails before
    /// `setupComplete`.
    func start() async throws {
        if isClosed { throw GeminiLiveError.alreadyClosed }
        if hasStarted { throw GeminiLiveError.alreadyStarted }
        hasStarted = true

        try await openChannelAndSendSetup()
        try await awaitSetupComplete()
    }

    /// Base64-encode `pcm16` and forward as a `realtimeInput.audio` frame.
    /// Silently no-ops while the session is mid-reconnect — Gemini's transient
    /// drops should not bubble up as errors here.
    func sendAudio(_ pcm16: Data) async throws {
        if isClosed { throw GeminiLiveError.alreadyClosed }
        guard let channel else { return }
        let body = Self.encodeAudioFrame(pcm16)
        try await channel.send(text: body)
    }

    func close() async {
        if isClosed { return }
        isClosed = true
        receiveTask?.cancel()
        receiveTask = nil
        channel?.cancel(code: 1000, reason: nil)
        channel = nil
        eventsContinuation.finish()
        if let cont = setupContinuation {
            setupContinuation = nil
            cont.resume(throwing: GeminiLiveError.alreadyClosed)
        }
    }

    // MARK: - Connection

    private func openChannelAndSendSetup() async throws {
        if isClosed { return }
        let url = Self.buildURL(apiKey: apiKey)
        let ch = channelFactory(url)
        self.channel = ch
        ch.resume()
        try await ch.send(text: Self.encodeSetupMessage(model: model))
        startReceiveLoop(channel: ch)
    }

    private func awaitSetupComplete() async throws {
        if isReady { return }
        if isClosed { throw GeminiLiveError.alreadyClosed }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            if isReady { cont.resume(); return }
            if isClosed { cont.resume(throwing: GeminiLiveError.alreadyClosed); return }
            setupContinuation = cont
        }
    }

    private func startReceiveLoop(channel: any GeminiWebSocketChannel) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let msg = try await channel.receive()
                    guard let self else { return }
                    await self.handleIncoming(msg)
                } catch {
                    guard let self else { return }
                    await self.handleReceiveError(error)
                    return
                }
            }
        }
    }

    private func handleIncoming(_ msg: WebSocketIncoming) {
        let payload: Data
        switch msg {
        case .text(let s): payload = Data(s.utf8)
        case .data(let d): payload = d
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
            return
        }

        if obj["setupComplete"] != nil {
            isReady = true
            reconnectAttempts = 0
            if let cont = setupContinuation {
                setupContinuation = nil
                cont.resume()
            }
            return
        }

        guard let serverContent = obj["serverContent"] as? [String: Any] else { return }
        guard let inputTranscription = serverContent["inputTranscription"] as? [String: Any] else {
            return
        }
        guard let text = inputTranscription["text"] as? String, !text.isEmpty else { return }
        eventsContinuation.yield(.partial(text))
    }

    private func handleReceiveError(_ error: Error) async {
        if isClosed { return }
        isReady = false
        channel?.cancel(code: 1006, reason: nil)
        channel = nil

        if reconnectAttempts >= Self.maxReconnectAttempts {
            if let cont = setupContinuation {
                setupContinuation = nil
                cont.resume(throwing: GeminiLiveError.maxReconnectAttemptsReached)
            }
            return
        }
        let attempt = reconnectAttempts
        reconnectAttempts += 1
        let delay = min(
            Self.initialReconnectDelay * pow(2.0, Double(attempt)),
            Self.maxReconnectDelay
        )
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        if isClosed { return }
        do {
            try await openChannelAndSendSetup()
        } catch {
            await handleReceiveError(error)
        }
    }

    // MARK: - Wire format

    static func buildURL(apiKey: String) -> URL {
        var components = URLComponents(
            string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        )!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        return components.url!
    }

    /// JSON body for the setup frame. Encoded with sorted keys so unit tests
    /// can byte-compare deterministically.
    static func encodeSetupMessage(model: String) -> String {
        let payload: [String: Any] = [
            "config": [
                "model": "models/\(model)",
                "responseModalities": ["TEXT"],
                "inputAudioTranscription": [String: String](),
                "systemInstruction": [
                    "parts": [
                        ["text": "Transcribe the user's spoken words verbatim. Do not respond. Do not paraphrase. Output exactly what was said."]
                    ]
                ]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func encodeAudioFrame(_ pcm16: Data) -> String {
        let payload: [String: Any] = [
            "realtimeInput": [
                "audio": [
                    "data": pcm16.base64EncodedString(),
                    "mimeType": "audio/pcm;rate=16000"
                ]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - URLSession-backed channel

/// Production wrapper around `URLSessionWebSocketTask`. Marked `@unchecked
/// Sendable` because `URLSessionWebSocketTask` is a reference type that's
/// safe to send across isolation boundaries even though Foundation does not
/// yet annotate it as such.
final class URLSessionGeminiChannel: GeminiWebSocketChannel, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func resume() {
        task.resume()
    }

    func send(text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> WebSocketIncoming {
        let msg = try await task.receive()
        switch msg {
        case .string(let s): return .text(s)
        case .data(let d): return .data(d)
        @unknown default: return .data(Data())
        }
    }

    func cancel(code: Int, reason: Data?) {
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
        task.cancel(with: closeCode, reason: reason)
    }

    static let defaultFactory: @Sendable (URL) -> any GeminiWebSocketChannel = { url in
        let task = URLSession.shared.webSocketTask(with: url)
        return URLSessionGeminiChannel(task: task)
    }
}
