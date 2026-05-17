import AVFoundation
import Foundation
import Observation

/// Resolved Gemini credentials for a single live session — read on the main
/// actor at focus-change time so config edits in Settings take effect on the
/// next focus event without a restart.
struct SpeechCredentials: Equatable, Sendable {
    let apiKey: String
    let model: String
}

/// Abstraction over `AVAudioApplication.requestRecordPermission` so tests can
/// inject a synchronous allow/deny without touching real audio.
protocol MicPermissionRequesting: Sendable {
    func requestPermission() async -> Bool
}

struct AVAudioApplicationMicPermission: MicPermissionRequesting {
    func requestPermission() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }
}

/// Stoppable handle returned by the audio pipeline starter. Lets tests inject
/// a no-op pipeline and lets `SpeechCoordinator` tear it down on focus change.
@MainActor
protocol AudioPipelineHandle: AnyObject {
    func stop()
}

/// Singleton owned by the app for the duration of its lifetime. Bridges three
/// inputs into one output:
///   - `FocusStore.focusedTabID` (which tab to dictate into)
///   - `AVAudioEngine` mic capture, converted by `AudioFormatConverter`
///   - `GeminiLiveSession` transcript stream
/// → `partialTranscript` updates that the transcript pill (T-017) renders and
/// that the commit logic (T-018) reads.
///
/// Focus change semantics: close the current `GeminiLiveSession` (and stop the
/// mic tap), reset `partialTranscript`, then if a new focus exists AND a Gemini
/// key+model are configured AND the mic permission is granted, open a new
/// session and restart the mic. The WebSocket is **not** torn down on commit
/// (T-018) — only on focus change or app shutdown.
@MainActor
@Observable
final class SpeechCoordinator {
    static let shared = SpeechCoordinator()

    /// Trailing keyword triggers that commit the buffer immediately. Both have
    /// a leading space so an utterance like "send me a file" does NOT commit
    /// while "echo hi send" does.
    static let triggerWords: [String] = [" send", " enter"]

    /// Latest accumulated partial transcript. Cleared on focus change, on
    /// `clearTranscript()`, and after a commit (T-018). Gemini emits
    /// incremental fragments, so each event appends.
    private(set) var partialTranscript: String = ""

    /// Last user-actionable error from the speech pipeline (mic denied, setup
    /// failed, etc). T-025 will surface this via `ErrorBus`.
    private(set) var lastError: String?

    /// True while a Gemini Live session is open and the mic tap is running.
    private(set) var isStreaming: Bool = false

    /// Pause length (seconds) without new transcript fragments that forces a
    /// silence commit. Injectable for tests to drive the timer fast.
    @ObservationIgnored var silenceInterval: TimeInterval = 1.0

    /// Supplies the active Gemini credentials. Wired by the app at startup so
    /// the coordinator stays decoupled from SwiftData and Keychain types.
    @ObservationIgnored var credentialsProvider: (@MainActor () -> SpeechCredentials?)?

    /// Builds a fresh `GeminiLiveSession` for a focus change. Replaceable by
    /// tests to inject a session backed by a stub channel.
    @ObservationIgnored var sessionFactory: @MainActor (SpeechCredentials) -> GeminiLiveSession = { creds in
        GeminiLiveSession(apiKey: creds.apiKey, model: creds.model)
    }

    /// Starts the mic capture pipeline forwarding into the session. Replaceable
    /// by tests to a no-op so the real `AVAudioEngine` is never touched.
    @ObservationIgnored var audioPipelineStarter: @MainActor (GeminiLiveSession) -> AudioPipelineHandle? = { session in
        AVAudioPipeline.start(forwardingTo: session)
    }

    /// Forwards committed transcript bytes to a terminal session. Default
    /// resolves the live session via `TerminalSessionRegistry.shared` so
    /// production wiring needs no extra plumbing; tests inject a recorder.
    @ObservationIgnored var commitDelivery: @MainActor (UUID, Data) -> Void = { tabID, data in
        TerminalSessionRegistry.shared.sessionIfExists(tabID: tabID)?.send(data)
    }

    @ObservationIgnored var micPermission: any MicPermissionRequesting = AVAudioApplicationMicPermission()

    @ObservationIgnored private var currentSession: GeminiLiveSession?
    @ObservationIgnored private var transcriptTask: Task<Void, Never>?
    @ObservationIgnored private var audioHandle: AudioPipelineHandle?
    @ObservationIgnored private var lastFocusedTabID: UUID?
    @ObservationIgnored private var observationStarted = false
    @ObservationIgnored private var focusChangeTask: Task<Void, Never>?
    @ObservationIgnored private var silenceCommitTask: Task<Void, Never>?

    init() {}

    /// Begin observing `FocusStore`. Idempotent — safe to call from multiple
    /// view bootstraps. Also primes the pipeline against the current focus.
    func start() {
        if observationStarted { return }
        observationStarted = true
        observeFocus()
        let initial = FocusStore.shared.focusedTabID
        scheduleFocusChange(initial)
    }

    /// Resets the buffer but keeps the WebSocket open so the next utterance
    /// streams onto the existing session. Used by the auto-commit path in
    /// `commit(text:)` and also exposed for manual cancellation.
    func clearTranscript() {
        cancelSilenceTimer()
        partialTranscript = ""
    }

    /// Public entry point used by both the observation re-arm and tests.
    func handleFocusChange(_ newID: UUID?) async {
        if newID == lastFocusedTabID && currentSession != nil { return }
        lastFocusedTabID = newID

        await tearDown()

        guard newID != nil else { return }
        guard let creds = credentialsProvider?(),
              !creds.apiKey.isEmpty,
              !creds.model.isEmpty else {
            return
        }

        let granted = await micPermission.requestPermission()
        guard granted else {
            lastError = "Microphone permission denied. Open Settings to enable."
            return
        }

        let session = sessionFactory(creds)
        currentSession = session

        do {
            try await session.start()
        } catch {
            lastError = "Gemini Live setup failed: \(error)"
            await session.close()
            currentSession = nil
            return
        }

        let eventsStream = session.events
        transcriptTask = Task { @MainActor [weak self] in
            for await event in eventsStream {
                guard let self else { return }
                if Task.isCancelled { return }
                switch event {
                case .partial(let fragment):
                    self.partialTranscript.append(fragment)
                    self.onPartialAppended()
                }
            }
        }

        audioHandle = audioPipelineStarter(session)
        isStreaming = true
    }

    private func tearDown() async {
        isStreaming = false
        cancelSilenceTimer()
        transcriptTask?.cancel()
        transcriptTask = nil
        if let handle = audioHandle {
            audioHandle = nil
            handle.stop()
        }
        partialTranscript = ""
        if let session = currentSession {
            currentSession = nil
            await session.close()
        }
    }

    // MARK: - Commit logic (T-018)

    /// Runs after every appended partial fragment. Either commits immediately
    /// when the buffer ends in a trigger word, or (re)arms the silence timer.
    private func onPartialAppended() {
        let lower = partialTranscript.lowercased()
        for trigger in Self.triggerWords {
            if lower.hasSuffix(trigger) {
                let stripped = String(partialTranscript.dropLast(trigger.count))
                commit(text: stripped)
                return
            }
        }
        scheduleSilenceCommit()
    }

    private func scheduleSilenceCommit() {
        cancelSilenceTimer()
        let interval = silenceInterval
        silenceCommitTask = Task { @MainActor [weak self] in
            let nanos = UInt64(max(0, interval) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            if Task.isCancelled { return }
            guard let self else { return }
            self.commit(text: self.partialTranscript)
        }
    }

    private func cancelSilenceTimer() {
        silenceCommitTask?.cancel()
        silenceCommitTask = nil
    }

    /// Send `text + \r` to the currently focused tab and reset the buffer.
    /// Reads `FocusStore.shared.focusedTabID` **at commit time** so a focus
    /// change during the silence wait routes the commit to the new tab. The
    /// Gemini Live WebSocket is intentionally left open.
    private func commit(text rawText: String) {
        cancelSilenceTimer()
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            partialTranscript = ""
            return
        }
        guard let focusedID = FocusStore.shared.focusedTabID else {
            partialTranscript = ""
            return
        }
        let payload = Data((trimmed + "\r").utf8)
        commitDelivery(focusedID, payload)
        partialTranscript = ""
    }

    private func observeFocus() {
        withObservationTracking {
            _ = FocusStore.shared.focusedTabID
        } onChange: { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduleFocusChange(FocusStore.shared.focusedTabID)
                self.observeFocus()
            }
        }
    }

    private func scheduleFocusChange(_ newID: UUID?) {
        focusChangeTask?.cancel()
        focusChangeTask = Task { @MainActor [weak self] in
            await self?.handleFocusChange(newID)
        }
    }
}

// MARK: - Real audio pipeline

/// Production pipeline: configures the shared `AVAudioSession` for playback +
/// record, installs a tap on the input node, converts each buffer into PCM16
/// 16 kHz mono via `AudioFormatConverter`, and forwards the bytes to the
/// session's `sendAudio` actor method.
@MainActor
final class AVAudioPipeline: AudioPipelineHandle {
    private let engine: AVAudioEngine
    private let converter: AudioFormatConverter
    private weak var session: GeminiLiveSession?
    private var stopped = false

    private init(engine: AVAudioEngine, converter: AudioFormatConverter, session: GeminiLiveSession) {
        self.engine = engine
        self.converter = converter
        self.session = session
    }

    static func start(forwardingTo session: GeminiLiveSession) -> AVAudioPipeline? {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
            try audioSession.setActive(true, options: [])
        } catch {
            return nil
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return nil }
        guard let converter = AudioFormatConverter(inputFormat: inputFormat) else { return nil }

        let pipeline = AVAudioPipeline(engine: engine, converter: converter, session: session)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [converter, weak session] buffer, _ in
            guard let session else { return }
            guard let data = converter.convert(buffer) else { return }
            Task {
                try? await session.sendAudio(data)
            }
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            return nil
        }
        return pipeline
    }

    func stop() {
        if stopped { return }
        stopped = true
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
