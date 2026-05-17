import XCTest
@testable import vmux

final class OpenAIImageClientTests: XCTestCase {

    private static let apiKey = "sk-test-key"
    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Success

    func testSuccessSendsExpectedRequestBodyAndReturnsBytes() async throws {
        StubURLProtocol.setHandler { _ in
            (Self.okResponse(), Self.successBody(png: Self.png))
        }
        let client = OpenAIImageClient(session: Self.stubSession())

        let result = try await client.generatePanorama(
            prompt: "Mountain valley at dawn",
            apiKey: Self.apiKey
        )

        XCTAssertEqual(result.pngBytes, Self.png)
        XCTAssertNil(result.warning)

        let records = StubURLProtocol.takeRecords()
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.request.url, OpenAIImageClient.endpoint)
        XCTAssertEqual(record.request.httpMethod, "POST")
        XCTAssertEqual(record.request.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.apiKey)")
        XCTAssertEqual(record.request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try Self.decodedBody(record)
        XCTAssertEqual(body["model"] as? String, "gpt-image-2")
        XCTAssertEqual(body["size"] as? String, "2048x1024")
        XCTAssertEqual(body["response_format"] as? String, "b64_json")
        XCTAssertEqual(body["n"] as? Int, 1)
        let prompt = try XCTUnwrap(body["prompt"] as? String)
        XCTAssertTrue(prompt.hasPrefix("Mountain valley at dawn"))
        XCTAssertTrue(prompt.contains("360-degree equirectangular panorama"))
        XCTAssertTrue(prompt.contains("seamless horizontal wrap"))
    }

    // MARK: - Model fallback

    func testModelFallbackOn404RetriesWithGptImage1AndWarns() async throws {
        let queue = ResponseQueue(responses: [
            (Self.errorResponse(status: 404), Self.errorBody(code: "model_not_found", message: "Unknown model")),
            (Self.okResponse(), Self.successBody(png: Self.png)),
        ])
        StubURLProtocol.setHandler { _ in
            queue.next()
        }
        let client = OpenAIImageClient(session: Self.stubSession())

        let result = try await client.generatePanorama(prompt: "calm sea", apiKey: Self.apiKey)

        XCTAssertEqual(result.pngBytes, Self.png)
        XCTAssertEqual(result.warning, OpenAIImageClient.modelWarning)

        let records = StubURLProtocol.takeRecords()
        XCTAssertEqual(records.count, 2)
        let firstBody = try Self.decodedBody(records[0])
        XCTAssertEqual(firstBody["model"] as? String, "gpt-image-2")
        XCTAssertEqual(firstBody["size"] as? String, "2048x1024")
        let retryBody = try Self.decodedBody(records[1])
        XCTAssertEqual(retryBody["model"] as? String, "gpt-image-1")
        XCTAssertEqual(retryBody["size"] as? String, "2048x1024")
    }

    func testModelFallbackOn400InvalidModelRetriesWithGptImage1AndWarns() async throws {
        let queue = ResponseQueue(responses: [
            (Self.errorResponse(status: 400), Self.errorBody(code: "invalid_model", message: "Bad model")),
            (Self.okResponse(), Self.successBody(png: Self.png)),
        ])
        StubURLProtocol.setHandler { _ in
            queue.next()
        }
        let client = OpenAIImageClient(session: Self.stubSession())

        let result = try await client.generatePanorama(prompt: "neon city", apiKey: Self.apiKey)

        XCTAssertEqual(result.warning, OpenAIImageClient.modelWarning)
        let records = StubURLProtocol.takeRecords()
        XCTAssertEqual(records.count, 2)
        let retryBody = try Self.decodedBody(records[1])
        XCTAssertEqual(retryBody["model"] as? String, "gpt-image-1")
    }

    // MARK: - Size fallback

    func testSizeFallbackOn400InvalidSizeRetriesWith1024AndWarns() async throws {
        let queue = ResponseQueue(responses: [
            (Self.errorResponse(status: 400), Self.errorBody(code: "invalid_size", message: "Size not supported")),
            (Self.okResponse(), Self.successBody(png: Self.png)),
        ])
        StubURLProtocol.setHandler { _ in
            queue.next()
        }
        let client = OpenAIImageClient(session: Self.stubSession())

        let result = try await client.generatePanorama(prompt: "desert", apiKey: Self.apiKey)

        XCTAssertEqual(result.pngBytes, Self.png)
        XCTAssertEqual(result.warning, OpenAIImageClient.sizeWarning)

        let records = StubURLProtocol.takeRecords()
        XCTAssertEqual(records.count, 2)
        let firstBody = try Self.decodedBody(records[0])
        XCTAssertEqual(firstBody["model"] as? String, "gpt-image-2")
        XCTAssertEqual(firstBody["size"] as? String, "2048x1024")
        let retryBody = try Self.decodedBody(records[1])
        XCTAssertEqual(retryBody["model"] as? String, "gpt-image-2")
        XCTAssertEqual(retryBody["size"] as? String, "1024x1024")
    }

    // MARK: - Non-fallback error

    func testUnauthorizedErrorIsRaisedWithoutRetry() async {
        StubURLProtocol.setHandler { _ in
            (Self.errorResponse(status: 401), Self.errorBody(code: "invalid_api_key", message: "Bad key"))
        }
        let client = OpenAIImageClient(session: Self.stubSession())

        do {
            _ = try await client.generatePanorama(prompt: "anything", apiKey: Self.apiKey)
            XCTFail("Expected HTTP 401 to throw")
        } catch let OpenAIImageClientError.http(status, _) {
            XCTAssertEqual(status, 401)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.takeRequests().count, 1)
    }

    // MARK: - Helpers

    private static func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static func okResponse() -> HTTPURLResponse {
        HTTPURLResponse(
            url: OpenAIImageClient.endpoint,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    private static func errorResponse(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: OpenAIImageClient.endpoint,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    private static func successBody(png: Data) -> Data {
        let envelope: [String: Any] = [
            "data": [
                ["b64_json": png.base64EncodedString()]
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: envelope)
    }

    private static func errorBody(code: String, message: String) -> Data {
        let envelope: [String: Any] = [
            "error": [
                "code": code,
                "message": message,
                "type": "invalid_request_error",
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: envelope)
    }

    private static func decodedBody(_ record: RecordedRequest) throws -> [String: Any] {
        let bodyData = try XCTUnwrap(record.body, "no captured body for \(record.request)")
        let json = try JSONSerialization.jsonObject(with: bodyData)
        return try XCTUnwrap(json as? [String: Any])
    }
}

/// Sendable FIFO of canned responses. Used by the stub handler so the closure
/// stays Sendable-clean under Swift 6 strict concurrency.
private final class ResponseQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(HTTPURLResponse, Data)]

    init(responses: [(HTTPURLResponse, Data)]) {
        self.responses = responses
    }

    func next() -> (HTTPURLResponse, Data) {
        lock.lock(); defer { lock.unlock() }
        precondition(!responses.isEmpty, "ResponseQueue exhausted")
        return responses.removeFirst()
    }
}
