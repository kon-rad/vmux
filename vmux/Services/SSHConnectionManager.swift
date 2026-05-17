import Foundation
import Citadel
import Crypto
import NIOCore

extension Citadel.SSHClient: @unchecked @retroactive Sendable {}
extension Citadel.SSHAuthenticationMethod: @unchecked @retroactive Sendable {}

struct SSHProjectInfo: Sendable, Equatable, Hashable {
    let id: UUID
    let host: String
    let port: Int
    let username: String
    let authType: String
    let keychainRef: String
}

extension SSHProjectInfo {
    @MainActor
    init(project: Project) {
        self.init(
            id: project.id,
            host: project.host,
            port: project.port,
            username: project.username,
            authType: project.authType,
            keychainRef: project.keychainRef
        )
    }
}

enum SSHConnectionError: Error, Equatable, CustomStringConvertible {
    case missingSecret
    case unsupportedAuthType(String)
    case unsupportedPrivateKeyType(String)
    case invalidPrivateKey(String)

    var description: String {
        switch self {
        case .missingSecret:
            return "No SSH credential found in Keychain for this project."
        case .unsupportedAuthType(let raw):
            return "Unsupported SSH authentication type: \(raw)."
        case .unsupportedPrivateKeyType(let raw):
            return "Unsupported private key type: \(raw). Use ed25519 or rsa."
        case .invalidPrivateKey(let reason):
            return "Couldn't parse private key: \(reason)"
        }
    }
}

actor SSHConnectionManager {
    static let shared = SSHConnectionManager()

    private let keychain: KeychainService
    private let connectTimeout: TimeAmount
    private var clients: [UUID: SSHClient] = [:]
    private var onProjectDisconnect: (@Sendable (UUID) async -> Void)?

    init(
        keychain: KeychainService = KeychainService(),
        connectTimeout: TimeAmount = .seconds(30)
    ) {
        self.keychain = keychain
        self.connectTimeout = connectTimeout
    }

    /// Register a handler invoked whenever an SSH client closes unexpectedly.
    /// `TerminalSessionRegistry` uses this to flip every terminal session whose
    /// `projectID` matches into `.disconnected` so the UI can surface the
    /// reconnect banner (T-024).
    func setOnProjectDisconnect(_ handler: @escaping @Sendable (UUID) async -> Void) {
        self.onProjectDisconnect = handler
    }

    func client(for info: SSHProjectInfo) async throws -> SSHClient {
        if let existing = clients[info.id], existing.isConnected {
            return existing
        }
        clients.removeValue(forKey: info.id)
        let client = try await openClient(for: info)
        clients[info.id] = client
        return client
    }

    func disconnect(projectID: UUID) async {
        guard let client = clients.removeValue(forKey: projectID) else { return }
        try? await client.close()
    }

    func disconnectAll() async {
        let snapshot = clients
        clients.removeAll()
        for (_, client) in snapshot {
            try? await client.close()
        }
    }

    private func openClient(for info: SSHProjectInfo) async throws -> SSHClient {
        guard let secret = try keychain.load(for: info.keychainRef), !secret.isEmpty else {
            throw SSHConnectionError.missingSecret
        }

        let authMethod = try Self.makeAuthenticationMethod(
            username: info.username,
            authType: info.authType,
            secret: secret
        )

        let client = try await SSHClient.connect(
            host: info.host,
            port: info.port,
            authenticationMethod: authMethod,
            hostKeyValidator: .acceptAnything(),
            reconnect: .never,
            connectTimeout: connectTimeout
        )

        let projectID = info.id
        client.onDisconnect { [weak self] in
            guard let self else { return }
            Task { await self.handleDisconnect(projectID: projectID) }
        }

        return client
    }

    private func handleDisconnect(projectID: UUID) {
        clients.removeValue(forKey: projectID)
        if let handler = onProjectDisconnect {
            Task { await handler(projectID) }
        }
    }

    nonisolated static func makeAuthenticationMethod(
        username: String,
        authType: String,
        secret: String
    ) throws -> SSHAuthenticationMethod {
        switch authType {
        case "password":
            return .passwordBased(username: username, password: secret)
        case "privateKey":
            return try makePrivateKeyAuthMethod(username: username, secret: secret)
        default:
            throw SSHConnectionError.unsupportedAuthType(authType)
        }
    }

    private nonisolated static func makePrivateKeyAuthMethod(
        username: String,
        secret: String
    ) throws -> SSHAuthenticationMethod {
        let detected: SSHKeyType
        do {
            detected = try SSHKeyDetection.detectPrivateKeyType(from: secret)
        } catch {
            throw SSHConnectionError.invalidPrivateKey(String(describing: error))
        }

        switch detected {
        case .ed25519:
            let key: Curve25519.Signing.PrivateKey
            do {
                key = try Curve25519.Signing.PrivateKey(sshEd25519: secret)
            } catch {
                throw SSHConnectionError.invalidPrivateKey(String(describing: error))
            }
            return .ed25519(username: username, privateKey: key)
        case .rsa:
            let key: Insecure.RSA.PrivateKey
            do {
                key = try Insecure.RSA.PrivateKey(sshRsa: secret)
            } catch {
                throw SSHConnectionError.invalidPrivateKey(String(describing: error))
            }
            return .rsa(username: username, privateKey: key)
        default:
            throw SSHConnectionError.unsupportedPrivateKeyType(detected.rawValue)
        }
    }
}
