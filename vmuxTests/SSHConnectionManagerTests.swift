import XCTest
import Citadel
@testable import vmux

final class SSHConnectionManagerTests: XCTestCase {
    private let keychain = KeychainService()
    private var refs: [String] = []

    override func tearDownWithError() throws {
        for ref in refs {
            try? keychain.delete(for: ref)
        }
        refs.removeAll()
    }

    private func storeSecret(_ secret: String) throws -> String {
        let ref = "ssh-test-\(UUID().uuidString)"
        refs.append(ref)
        try keychain.save(secret, for: ref)
        return ref
    }

    // MARK: - Auth method factory

    func testPasswordAuthMethodIsBuilt() throws {
        XCTAssertNoThrow(
            try SSHConnectionManager.makeAuthenticationMethod(
                username: "alice",
                authType: "password",
                secret: "hunter2"
            )
        )
    }

    func testUnknownAuthTypeThrows() {
        XCTAssertThrowsError(
            try SSHConnectionManager.makeAuthenticationMethod(
                username: "alice",
                authType: "oauth",
                secret: "irrelevant"
            )
        ) { error in
            guard case SSHConnectionError.unsupportedAuthType(let raw) = error else {
                XCTFail("Expected unsupportedAuthType, got \(error)")
                return
            }
            XCTAssertEqual(raw, "oauth")
        }
    }

    func testGarbledPrivateKeyThrows() {
        XCTAssertThrowsError(
            try SSHConnectionManager.makeAuthenticationMethod(
                username: "alice",
                authType: "privateKey",
                secret: "not-a-real-key"
            )
        ) { error in
            guard case SSHConnectionError.invalidPrivateKey = error else {
                XCTFail("Expected invalidPrivateKey, got \(error)")
                return
            }
        }
    }

    // MARK: - Missing-secret path

    func testClientThrowsWhenSecretMissing() async {
        let info = SSHProjectInfo(
            id: UUID(),
            host: "127.0.0.1",
            port: 22,
            username: "alice",
            authType: "password",
            keychainRef: "missing-\(UUID().uuidString)"
        )
        let manager = SSHConnectionManager()

        do {
            _ = try await manager.client(for: info)
            XCTFail("Expected missingSecret error")
        } catch SSHConnectionError.missingSecret {
            // success
        } catch {
            XCTFail("Expected missingSecret, got \(error)")
        }
    }

    // MARK: - Live integration (skipped unless VMUX_TEST_HOST is set)

    func testLiveConnectAndEchoOK() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["VMUX_TEST_HOST"], !host.isEmpty else {
            throw XCTSkip("VMUX_TEST_HOST not set; skipping live SSH integration test.")
        }
        guard let username = env["VMUX_TEST_USER"], !username.isEmpty else {
            throw XCTSkip("VMUX_TEST_USER not set; skipping live SSH integration test.")
        }

        let port = Int(env["VMUX_TEST_PORT"] ?? "22") ?? 22

        let secret: String
        let authType: String
        if let password = env["VMUX_TEST_PASSWORD"], !password.isEmpty {
            secret = password
            authType = "password"
        } else if let key = env["VMUX_TEST_KEY"], !key.isEmpty {
            secret = key
            authType = "privateKey"
        } else if let keyPath = env["VMUX_TEST_KEY_PATH"], !keyPath.isEmpty {
            secret = try String(contentsOfFile: keyPath, encoding: .utf8)
            authType = "privateKey"
        } else {
            throw XCTSkip("VMUX_TEST_PASSWORD, VMUX_TEST_KEY or VMUX_TEST_KEY_PATH must be set; skipping.")
        }

        let ref = try storeSecret(secret)
        let info = SSHProjectInfo(
            id: UUID(),
            host: host,
            port: port,
            username: username,
            authType: authType,
            keychainRef: ref
        )

        let manager = SSHConnectionManager()
        let client = try await manager.client(for: info)
        XCTAssertTrue(client.isConnected, "Client should report connected after successful login")

        let output = try await client.executeCommand("echo ok")
        let text = String(buffer: output).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(text, "ok")

        let cached = try await manager.client(for: info)
        XCTAssertTrue(cached === client, "Subsequent client(for:) calls should return the cached client")

        await manager.disconnect(projectID: info.id)
    }
}
