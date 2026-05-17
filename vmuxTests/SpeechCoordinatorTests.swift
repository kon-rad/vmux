import XCTest
@testable import vmux

@MainActor
final class SpeechCoordinatorTests: XCTestCase {
    func test_focusChange_opensSession_andAppendsPartialFragments() async throws {
        let stub = StubGeminiChannel()
        let coordinator = makeCoordinator(stub: stub, granted: true)
        let tabID = UUID()

        let focusTask = Task { @MainActor in
            await coordinator.handleFocusChange(tabID)
        }

        _ = try await stub.nextSent(timeout: 1.0) // setup message
        await stub.push(.text("{\"setupComplete\":{}}"))
        await focusTask.value

        XCTAssertTrue(coordinator.isStreaming)
        XCTAssertNil(coordinator.lastError)

        await stub.push(.text("{\"serverContent\":{\"inputTranscription\":{\"text\":\"hello\"}}}"))
        await stub.push(.text("{\"serverContent\":{\"inputTranscription\":{\"text\":\" world\"}}}"))

        try await waitFor(timeout: 1.0) {
            await MainActor.run { coordinator.partialTranscript == "hello world" }
        }
        XCTAssertEqual(coordinator.partialTranscript, "hello world")
    }

    func test_focusChange_toNewTab_closesPriorSession_andResetsBuffer() async throws {
        let stub1 = StubGeminiChannel()
        let stub2 = StubGeminiChannel()

        var queue: [StubGeminiChannel] = [stub1, stub2]
        let coordinator = SpeechCoordinator()
        coordinator.micPermission = AlwaysGrantedMic()
        coordinator.credentialsProvider = {
            SpeechCredentials(apiKey: "K", model: "gemini-2.5-flash")
        }
        coordinator.audioPipelineStarter = { _ in NoopAudioHandle() }
        coordinator.sessionFactory = { @MainActor creds in
            let next = queue.removeFirst()
            return GeminiLiveSession(
                apiKey: creds.apiKey,
                model: creds.model,
                channelFactory: { _ in next }
            )
        }

        let tabA = UUID()
        let tabB = UUID()

        let focusA = Task { @MainActor in
            await coordinator.handleFocusChange(tabA)
        }
        _ = try await stub1.nextSent(timeout: 1.0)
        await stub1.push(.text("{\"setupComplete\":{}}"))
        await focusA.value

        await stub1.push(.text("{\"serverContent\":{\"inputTranscription\":{\"text\":\"hi\"}}}"))
        try await waitFor(timeout: 1.0) {
            await MainActor.run { coordinator.partialTranscript == "hi" }
        }

        let focusB = Task { @MainActor in
            await coordinator.handleFocusChange(tabB)
        }
        _ = try await stub2.nextSent(timeout: 1.0)
        await stub2.push(.text("{\"setupComplete\":{}}"))
        await focusB.value

        XCTAssertEqual(coordinator.partialTranscript, "", "Partial transcript must reset on focus change")
        XCTAssertTrue(stub1.didCancel, "Prior session's WebSocket must be cancelled on focus change")
        XCTAssertTrue(coordinator.isStreaming)
    }

    func test_focusChange_toNil_tearsDownSession() async throws {
        let stub = StubGeminiChannel()
        let coordinator = makeCoordinator(stub: stub, granted: true)
        let tabID = UUID()

        let focusTask = Task { @MainActor in
            await coordinator.handleFocusChange(tabID)
        }
        _ = try await stub.nextSent(timeout: 1.0)
        await stub.push(.text("{\"setupComplete\":{}}"))
        await focusTask.value

        await coordinator.handleFocusChange(nil)
        XCTAssertFalse(coordinator.isStreaming)
        XCTAssertTrue(stub.didCancel)
        XCTAssertEqual(coordinator.partialTranscript, "")
    }

    func test_clearTranscript_resetsBuffer_butKeepsSessionOpen() async throws {
        let stub = StubGeminiChannel()
        let coordinator = makeCoordinator(stub: stub, granted: true)
        let tabID = UUID()

        let focusTask = Task { @MainActor in
            await coordinator.handleFocusChange(tabID)
        }
        _ = try await stub.nextSent(timeout: 1.0)
        await stub.push(.text("{\"setupComplete\":{}}"))
        await focusTask.value

        await stub.push(.text("{\"serverContent\":{\"inputTranscription\":{\"text\":\"ls\"}}}"))
        try await waitFor(timeout: 1.0) {
            await MainActor.run { coordinator.partialTranscript == "ls" }
        }

        coordinator.clearTranscript()
        XCTAssertEqual(coordinator.partialTranscript, "")
        XCTAssertTrue(coordinator.isStreaming, "clearTranscript() must NOT close the session")
        XCTAssertFalse(stub.didCancel)

        await stub.push(.text("{\"serverContent\":{\"inputTranscription\":{\"text\":\"pwd\"}}}"))
        try await waitFor(timeout: 1.0) {
            await MainActor.run { coordinator.partialTranscript == "pwd" }
        }
    }

    func test_micDenied_setsLastError_andDoesNotOpenSession() async throws {
        var stubBuilt = false
        let stub = StubGeminiChannel()
        let coordinator = SpeechCoordinator()
        coordinator.micPermission = AlwaysDeniedMic()
        coordinator.credentialsProvider = {
            SpeechCredentials(apiKey: "K", model: "gemini-2.5-flash")
        }
        coordinator.audioPipelineStarter = { _ in NoopAudioHandle() }
        coordinator.sessionFactory = { @MainActor creds in
            stubBuilt = true
            return GeminiLiveSession(
                apiKey: creds.apiKey,
                model: creds.model,
                channelFactory: { _ in stub }
            )
        }

        await coordinator.handleFocusChange(UUID())
        XCTAssertFalse(stubBuilt, "Session must not be constructed when mic permission denied")
        XCTAssertFalse(coordinator.isStreaming)
        XCTAssertNotNil(coordinator.lastError)
    }

    func test_missingCredentials_noOps() async {
        let coordinator = SpeechCoordinator()
        coordinator.micPermission = AlwaysGrantedMic()
        coordinator.credentialsProvider = { nil }
        coordinator.audioPipelineStarter = { _ in NoopAudioHandle() }

        await coordinator.handleFocusChange(UUID())
        XCTAssertFalse(coordinator.isStreaming)
        XCTAssertNil(coordinator.lastError)
    }

    // MARK: - T-018 commit-on-pause / keyword

    func test_trailingSend_commitsImmediately_andStripsTriggerWord() async throws {
        let stub = StubGeminiChannel()
        let recorder = CommitRecorder()
        let coordinator = makeCommitCoordinator(stub: stub, recorder: recorder)

        let tabID = UUID()
        FocusStore.shared.focusedTabID = tabID

        try await openSession(coordinator: coordinator, stub: stub, tabID: tabID)

        await stub.push(.text(transcriptFrame("list home directory")))
        await stub.push(.text(transcriptFrame(" send")))

        try await waitFor(timeout: 1.0) { recorder.count == 1 }
        XCTAssertEqual(recorder.entries.first?.tabID, tabID)
        XCTAssertEqual(recorder.entries.first?.data, Data("list home directory\r".utf8))
        XCTAssertEqual(coordinator.partialTranscript, "")
        XCTAssertTrue(coordinator.isStreaming)
        XCTAssertFalse(stub.didCancel, "Commit must not close the WebSocket")
    }

    func test_trailingEnter_triggersCommitToo() async throws {
        let stub = StubGeminiChannel()
        let recorder = CommitRecorder()
        let coordinator = makeCommitCoordinator(stub: stub, recorder: recorder)

        let tabID = UUID()
        FocusStore.shared.focusedTabID = tabID
        try await openSession(coordinator: coordinator, stub: stub, tabID: tabID)

        await stub.push(.text(transcriptFrame("clear screen enter")))

        try await waitFor(timeout: 1.0) { recorder.count == 1 }
        XCTAssertEqual(recorder.entries.first?.data, Data("clear screen\r".utf8))
    }

    func test_triggerWord_isCaseInsensitive() async throws {
        let stub = StubGeminiChannel()
        let recorder = CommitRecorder()
        let coordinator = makeCommitCoordinator(stub: stub, recorder: recorder)

        let tabID = UUID()
        FocusStore.shared.focusedTabID = tabID
        try await openSession(coordinator: coordinator, stub: stub, tabID: tabID)

        await stub.push(.text(transcriptFrame("hello SEND")))

        try await waitFor(timeout: 1.0) { recorder.count == 1 }
        XCTAssertEqual(recorder.entries.first?.data, Data("hello\r".utf8))
    }

    func test_silence_commitsBuffer_afterIdleDelay() async throws {
        let stub = StubGeminiChannel()
        let recorder = CommitRecorder()
        let coordinator = makeCommitCoordinator(stub: stub, recorder: recorder)
        coordinator.silenceInterval = 0.1

        let tabID = UUID()
        FocusStore.shared.focusedTabID = tabID
        try await openSession(coordinator: coordinator, stub: stub, tabID: tabID)

        await stub.push(.text(transcriptFrame("ls -la")))

        try await waitFor(timeout: 1.0) { recorder.count == 1 }
        XCTAssertEqual(recorder.entries.first?.tabID, tabID)
        XCTAssertEqual(recorder.entries.first?.data, Data("ls -la\r".utf8))
        XCTAssertEqual(coordinator.partialTranscript, "")
        XCTAssertFalse(stub.didCancel)
    }

    func test_silence_isResetByNewFragment() async throws {
        let stub = StubGeminiChannel()
        let recorder = CommitRecorder()
        let coordinator = makeCommitCoordinator(stub: stub, recorder: recorder)
        coordinator.silenceInterval = 0.2

        let tabID = UUID()
        FocusStore.shared.focusedTabID = tabID
        try await openSession(coordinator: coordinator, stub: stub, tabID: tabID)

        await stub.push(.text(transcriptFrame("echo")))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(recorder.count, 0, "Silence must not have fired yet")
        await stub.push(.text(transcriptFrame(" hi")))

        try await waitFor(timeout: 1.0) { recorder.count == 1 }
        XCTAssertEqual(recorder.entries.first?.data, Data("echo hi\r".utf8))
    }

    func test_consecutiveCommits_keepWebSocketOpen() async throws {
        let stub = StubGeminiChannel()
        let recorder = CommitRecorder()
        let coordinator = makeCommitCoordinator(stub: stub, recorder: recorder)
        coordinator.silenceInterval = 0.05

        let tabID = UUID()
        FocusStore.shared.focusedTabID = tabID
        try await openSession(coordinator: coordinator, stub: stub, tabID: tabID)

        await stub.push(.text(transcriptFrame("first command")))
        try await waitFor(timeout: 1.0) { recorder.count == 1 }

        XCTAssertFalse(stub.didCancel)
        XCTAssertTrue(coordinator.isStreaming)

        await stub.push(.text(transcriptFrame("second command")))
        try await waitFor(timeout: 1.0) { recorder.count == 2 }

        XCTAssertEqual(recorder.entries[0].data, Data("first command\r".utf8))
        XCTAssertEqual(recorder.entries[1].data, Data("second command\r".utf8))
        XCTAssertFalse(stub.didCancel, "WebSocket must stay open across commits")
    }

    func test_commit_readsFocus_atCommitTime_notSpeechStartTime() async throws {
        let stub = StubGeminiChannel()
        let recorder = CommitRecorder()
        let coordinator = makeCommitCoordinator(stub: stub, recorder: recorder)
        coordinator.silenceInterval = 0.15

        let tabA = UUID()
        let tabB = UUID()
        FocusStore.shared.focusedTabID = tabA
        try await openSession(coordinator: coordinator, stub: stub, tabID: tabA)

        await stub.push(.text(transcriptFrame("echo race")))

        // Move focus directly via FocusStore — the coordinator's observation
        // is not started in tests, so the session is *not* torn down. This
        // simulates a focus race where the commit must route to the new tab.
        FocusStore.shared.focusedTabID = tabB

        try await waitFor(timeout: 1.0) { recorder.count == 1 }
        XCTAssertEqual(recorder.entries.first?.tabID, tabB)
        XCTAssertEqual(recorder.entries.first?.data, Data("echo race\r".utf8))
    }

    func test_focusChangeViaHandleFocusChange_dropsInFlightTranscript() async throws {
        let stub1 = StubGeminiChannel()
        let stub2 = StubGeminiChannel()
        var queue: [StubGeminiChannel] = [stub1, stub2]
        let recorder = CommitRecorder()

        let coordinator = SpeechCoordinator()
        coordinator.silenceInterval = 0.1
        coordinator.micPermission = AlwaysGrantedMic()
        coordinator.credentialsProvider = {
            SpeechCredentials(apiKey: "K", model: "gemini-2.5-flash")
        }
        coordinator.audioPipelineStarter = { _ in NoopAudioHandle() }
        coordinator.sessionFactory = { @MainActor creds in
            let next = queue.removeFirst()
            return GeminiLiveSession(
                apiKey: creds.apiKey,
                model: creds.model,
                channelFactory: { _ in next }
            )
        }
        coordinator.commitDelivery = { tabID, data in
            recorder.record(tabID: tabID, data: data)
        }

        let tabA = UUID()
        let tabB = UUID()

        FocusStore.shared.focusedTabID = tabA
        let focusA = Task { @MainActor in await coordinator.handleFocusChange(tabA) }
        _ = try await stub1.nextSent(timeout: 1.0)
        await stub1.push(.text("{\"setupComplete\":{}}"))
        await focusA.value

        await stub1.push(.text(transcriptFrame("half spoken")))
        try await waitFor(timeout: 1.0) {
            await MainActor.run { coordinator.partialTranscript == "half spoken" }
        }

        FocusStore.shared.focusedTabID = tabB
        let focusB = Task { @MainActor in await coordinator.handleFocusChange(tabB) }
        _ = try await stub2.nextSent(timeout: 1.0)
        await stub2.push(.text("{\"setupComplete\":{}}"))
        await focusB.value

        // Wait long enough for any straggling silence timer to have fired.
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(recorder.count, 0, "Mid-utterance focus change must discard the buffer")
        XCTAssertEqual(coordinator.partialTranscript, "")
        XCTAssertTrue(stub1.didCancel)
        XCTAssertFalse(stub2.didCancel)
    }

    func test_emptyBuffer_doesNotCommit() async throws {
        let stub = StubGeminiChannel()
        let recorder = CommitRecorder()
        let coordinator = makeCommitCoordinator(stub: stub, recorder: recorder)
        coordinator.silenceInterval = 0.05

        let tabID = UUID()
        FocusStore.shared.focusedTabID = tabID
        try await openSession(coordinator: coordinator, stub: stub, tabID: tabID)

        // Push only whitespace — appending it should not produce a commit.
        await stub.push(.text(transcriptFrame("   ")))

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(recorder.count, 0)
        XCTAssertEqual(coordinator.partialTranscript, "")
    }

    // MARK: - Helpers

    private func makeCoordinator(stub: StubGeminiChannel, granted: Bool) -> SpeechCoordinator {
        let coordinator = SpeechCoordinator()
        coordinator.micPermission = granted ? AlwaysGrantedMic() : AlwaysDeniedMic()
        coordinator.credentialsProvider = {
            SpeechCredentials(apiKey: "K", model: "gemini-2.5-flash")
        }
        coordinator.audioPipelineStarter = { _ in NoopAudioHandle() }
        coordinator.sessionFactory = { @MainActor creds in
            GeminiLiveSession(
                apiKey: creds.apiKey,
                model: creds.model,
                channelFactory: { _ in stub }
            )
        }
        return coordinator
    }

    private func waitFor(timeout: TimeInterval, _ condition: @escaping () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Condition did not become true within \(timeout)s")
    }

    private func waitFor(timeout: TimeInterval, _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Condition did not become true within \(timeout)s")
    }

    private func makeCommitCoordinator(stub: StubGeminiChannel, recorder: CommitRecorder) -> SpeechCoordinator {
        let coordinator = SpeechCoordinator()
        coordinator.micPermission = AlwaysGrantedMic()
        coordinator.credentialsProvider = {
            SpeechCredentials(apiKey: "K", model: "gemini-2.5-flash")
        }
        coordinator.audioPipelineStarter = { _ in NoopAudioHandle() }
        coordinator.sessionFactory = { @MainActor creds in
            GeminiLiveSession(
                apiKey: creds.apiKey,
                model: creds.model,
                channelFactory: { _ in stub }
            )
        }
        coordinator.commitDelivery = { tabID, data in
            recorder.record(tabID: tabID, data: data)
        }
        return coordinator
    }

    private func openSession(
        coordinator: SpeechCoordinator,
        stub: StubGeminiChannel,
        tabID: UUID
    ) async throws {
        let task = Task { @MainActor in await coordinator.handleFocusChange(tabID) }
        _ = try await stub.nextSent(timeout: 1.0)
        await stub.push(.text("{\"setupComplete\":{}}"))
        await task.value
    }

    private func transcriptFrame(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"serverContent\":{\"inputTranscription\":{\"text\":\"\(escaped)\"}}}"
    }
}

@MainActor
final class CommitRecorder {
    struct Entry: Sendable {
        let tabID: UUID
        let data: Data
    }
    private(set) var entries: [Entry] = []
    var count: Int { entries.count }

    func record(tabID: UUID, data: Data) {
        entries.append(Entry(tabID: tabID, data: data))
    }
}

private struct AlwaysGrantedMic: MicPermissionRequesting {
    func requestPermission() async -> Bool { true }
}

private struct AlwaysDeniedMic: MicPermissionRequesting {
    func requestPermission() async -> Bool { false }
}

@MainActor
private final class NoopAudioHandle: AudioPipelineHandle {
    func stop() {}
}
