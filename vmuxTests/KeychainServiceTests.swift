import XCTest
@testable import vmux

final class KeychainServiceTests: XCTestCase {
    private let keychain = KeychainService()
    private var refs: [String] = []

    override func tearDownWithError() throws {
        for ref in refs {
            try? keychain.delete(for: ref)
        }
        refs.removeAll()
    }

    private func makeRef() -> String {
        let ref = "test-\(UUID().uuidString)"
        refs.append(ref)
        return ref
    }

    func testRoundTripsSecret() throws {
        let ref = makeRef()
        try keychain.save("hunter2", for: ref)
        XCTAssertEqual(try keychain.load(for: ref), "hunter2")
    }

    func testSaveOverwritesExistingValue() throws {
        let ref = makeRef()
        try keychain.save("first", for: ref)
        try keychain.save("second", for: ref)
        XCTAssertEqual(try keychain.load(for: ref), "second")
    }

    func testDeleteRemovesSecret() throws {
        let ref = makeRef()
        try keychain.save("to-be-removed", for: ref)
        try keychain.delete(for: ref)
        XCTAssertNil(try keychain.load(for: ref))
    }

    func testLoadingMissingReturnsNil() throws {
        let ref = "missing-\(UUID().uuidString)"
        XCTAssertNil(try keychain.load(for: ref))
    }

    func testDeleteMissingIsIdempotent() throws {
        let ref = "missing-\(UUID().uuidString)"
        XCTAssertNoThrow(try keychain.delete(for: ref))
    }

    func testRoundTripsUnicodeSecret() throws {
        let ref = makeRef()
        let secret = "🔐 пароль パスワード"
        try keychain.save(secret, for: ref)
        XCTAssertEqual(try keychain.load(for: ref), secret)
    }
}
