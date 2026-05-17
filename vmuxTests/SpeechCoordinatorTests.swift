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
