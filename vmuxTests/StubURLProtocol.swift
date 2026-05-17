import Foundation

/// A `URLProtocol` subclass that intercepts requests issued by a `URLSession`
/// configured with `protocolClasses = [StubURLProtocol.self]`. Tests install a
/// handler closure that maps each incoming request to a canned
/// `(HTTPURLResponse, Data)` pair, and can inspect the captured request +
/// body bytes afterward.
///
/// `URLSession` may convert `httpBody` into an `httpBodyStream` before handing
/// the request to `URLProtocol`, and the stream is single-use. To keep tests
/// simple, the protocol drains the body during `canonicalRequest(for:)` and
/// stores the bytes alongside the request as `RecordedRequest.body`.
struct RecordedRequest: Sendable {
    let request: URLRequest
    let body: Data?
}

final class StubURLProtocol: URLProtocol {

    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: Handler?
    nonisolated(unsafe) private static var _records: [RecordedRequest] = []

    static func setHandler(_ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        _handler = handler
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _handler = nil
        _records = []
    }

    static func takeRecords() -> [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        let snapshot = _records
        _records = []
        return snapshot
    }

    static func takeRequests() -> [URLRequest] {
        takeRecords().map(\.request)
    }

    private static func record(_ record: RecordedRequest) {
        lock.lock(); defer { lock.unlock() }
        _records.append(record)
    }

    private static func currentHandler() -> Handler? {
        lock.lock(); defer { lock.unlock() }
        return _handler
    }

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        var data = Data()
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private static func extractBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody, !body.isEmpty { return body }
        if let stream = request.httpBodyStream {
            return drain(stream)
        }
        return nil
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Self.extractBody(request)
        Self.record(RecordedRequest(request: request, body: body))

        guard let handler = Self.currentHandler() else {
            client?.urlProtocol(self, didFailWithError: NSError(
                domain: "StubURLProtocol",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No handler installed"]
            ))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
