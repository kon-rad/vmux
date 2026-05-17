import SwiftUI
import SwiftData

struct NewProjectSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    enum AuthMode: String, CaseIterable, Identifiable {
        case password
        case privateKey

        var id: String { rawValue }

        var label: String {
            switch self {
            case .password: "Password"
            case .privateKey: "Private Key"
            }
        }

        var storageValue: String {
            switch self {
            case .password: "password"
            case .privateKey: "privateKey"
            }
        }
    }

    @State private var name: String = ""
    @State private var host: String = ""
    @State private var portText: String = "22"
    @State private var username: String = ""
    @State private var authMode: AuthMode = .password
    @State private var password: String = ""
    @State private var privateKey: String = ""
    @State private var saveError: String?

    private let keychain: KeychainService

    init(keychain: KeychainService = KeychainService()) {
        self.keychain = keychain
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedUsername: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var portValue: Int? {
        Int(portText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var portIsValid: Bool {
        guard let port = portValue else { return false }
        return (1...65535).contains(port)
    }

    private var secret: String {
        switch authMode {
        case .password: password
        case .privateKey: privateKey
        }
    }

    private var canSave: Bool {
        !trimmedName.isEmpty &&
        !trimmedHost.isEmpty &&
        portIsValid &&
        !secret.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Connection") {
                    TextField("Host", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $portText)
                        .keyboardType(.numberPad)
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Authentication") {
                    Picker("Method", selection: $authMode) {
                        ForEach(AuthMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch authMode {
                    case .password:
                        SecureField("Password", text: $password)
                    case .privateKey:
                        TextEditor(text: $privateKey)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 140)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }

                if let saveError {
                    Section {
                        Text(saveError)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Project")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        guard let port = portValue, (1...65535).contains(port) else {
            saveError = "Port must be between 1 and 65535."
            return
        }
        guard !trimmedName.isEmpty, !trimmedHost.isEmpty else {
            saveError = "Name and host are required."
            return
        }
        guard !secret.isEmpty else {
            saveError = "Enter a password or private key."
            return
        }

        let keychainRef = UUID().uuidString
        do {
            try keychain.save(secret, for: keychainRef)
        } catch {
            saveError = "Couldn't save secret to Keychain: \(error)"
            return
        }

        let project = Project(
            name: trimmedName,
            host: trimmedHost,
            port: port,
            username: trimmedUsername,
            authType: authMode.storageValue,
            keychainRef: keychainRef
        )
        modelContext.insert(project)
        do {
            try modelContext.save()
        } catch {
            try? keychain.delete(for: keychainRef)
            saveError = "Couldn't save project: \(error)"
            return
        }

        dismiss()
    }
}

#Preview {
    NewProjectSheet()
        .modelContainer(for: [Project.self, Tab.self, AppSettings.self], inMemory: true)
}
