import SwiftUI
import SwiftData

struct SettingsView: View {
    @Query private var settingsRows: [AppSettings]

    var body: some View {
        Group {
            if let settings = settingsRows.first {
                SettingsForm(settings: settings)
            } else {
                ProgressView()
                    .frame(minWidth: 520, minHeight: 640)
            }
        }
    }
}

private enum GeminiModelMode: String, CaseIterable, Identifiable {
    case flash = "gemini-2.5-flash"
    case pro = "gemini-2.5-pro"
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .flash: "Flash (gemini-2.5-flash)"
        case .pro: "Pro (gemini-2.5-pro)"
        case .custom: "Custom…"
        }
    }

    static func mode(for model: String) -> GeminiModelMode {
        switch model {
        case GeminiModelMode.flash.rawValue: .flash
        case GeminiModelMode.pro.rawValue: .pro
        default: .custom
        }
    }
}

private enum TestState: Equatable {
    case idle
    case testing
    case success
    case failure(String)
}

private struct SettingsForm: View {
    @Bindable var settings: AppSettings

    @State private var openAIKey: String = ""
    @State private var geminiKey: String = ""
    @State private var geminiModelMode: GeminiModelMode = .flash
    @State private var customGeminiModel: String = ""
    @State private var openAITestState: TestState = .idle
    @State private var geminiTestState: TestState = .idle

    private let keychain = KeychainService()

    var body: some View {
        NavigationStack {
            Form {
                profileSection
                openAISection
                geminiSection
                idleSection
            }
            .navigationTitle("Settings")
        }
        .frame(minWidth: 520, minHeight: 640)
        .onAppear(perform: loadFromStorage)
    }

    private var profileSection: some View {
        Section("Profile") {
            TextField("Display Name", text: $settings.displayName)
                .textInputAutocapitalization(.words)
        }
    }

    private var openAISection: some View {
        Section("OpenAI API Key") {
            SecureField("sk-…", text: $openAIKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: openAIKey) { _, newValue in
                    persistOpenAIKey(newValue)
                    openAITestState = .idle
                }
            HStack {
                Button("Test") {
                    Task { await testOpenAI() }
                }
                .disabled(openAIKey.isEmpty || openAITestState == .testing)
                statusBadge(openAITestState)
            }
        }
    }

    private var geminiSection: some View {
        Section("Gemini API Key + Speech Model") {
            SecureField("AIza…", text: $geminiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: geminiKey) { _, newValue in
                    persistGeminiKey(newValue)
                    geminiTestState = .idle
                }

            Picker("Model", selection: $geminiModelMode) {
                ForEach(GeminiModelMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .onChange(of: geminiModelMode) { _, mode in
                switch mode {
                case .flash, .pro:
                    settings.geminiModel = mode.rawValue
                case .custom:
                    settings.geminiModel = customGeminiModel
                }
            }

            if geminiModelMode == .custom {
                TextField("Custom model id", text: $customGeminiModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: customGeminiModel) { _, newValue in
                        settings.geminiModel = newValue
                    }
            }

            HStack {
                Button("Test") {
                    Task { await testGemini() }
                }
                .disabled(geminiKey.isEmpty || geminiTestState == .testing)
                statusBadge(geminiTestState)
            }
        }
    }

    private var idleSection: some View {
        Section("Agent Detection") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Idle threshold: \(settings.idleThresholdSeconds) s")
                    .foregroundStyle(.secondary)
                Slider(
                    value: idleThresholdBinding,
                    in: 1...10,
                    step: 1
                ) {
                    Text("Idle threshold")
                } minimumValueLabel: {
                    Text("1s")
                } maximumValueLabel: {
                    Text("10s")
                }
            }
        }
    }

    private var idleThresholdBinding: Binding<Double> {
        Binding(
            get: { Double(settings.idleThresholdSeconds) },
            set: { settings.idleThresholdSeconds = Int($0.rounded()) }
        )
    }

    @ViewBuilder
    private func statusBadge(_ state: TestState) -> some View {
        switch state {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView()
        case .success:
            Label("OK", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let reason):
            Label(reason, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private func loadFromStorage() {
        if !settings.openAIKeychainRef.isEmpty {
            openAIKey = (try? keychain.load(for: settings.openAIKeychainRef)) ?? ""
        }
        if !settings.geminiKeychainRef.isEmpty {
            geminiKey = (try? keychain.load(for: settings.geminiKeychainRef)) ?? ""
        }
        geminiModelMode = GeminiModelMode.mode(for: settings.geminiModel)
        if geminiModelMode == .custom {
            customGeminiModel = settings.geminiModel
        }
    }

    private func persistOpenAIKey(_ key: String) {
        if key.isEmpty {
            if !settings.openAIKeychainRef.isEmpty {
                try? keychain.delete(for: settings.openAIKeychainRef)
            }
            return
        }
        if settings.openAIKeychainRef.isEmpty {
            settings.openAIKeychainRef = UUID().uuidString
        }
        try? keychain.save(key, for: settings.openAIKeychainRef)
    }

    private func persistGeminiKey(_ key: String) {
        if key.isEmpty {
            if !settings.geminiKeychainRef.isEmpty {
                try? keychain.delete(for: settings.geminiKeychainRef)
            }
            return
        }
        if settings.geminiKeychainRef.isEmpty {
            settings.geminiKeychainRef = UUID().uuidString
        }
        try? keychain.save(key, for: settings.geminiKeychainRef)
    }

    private func testOpenAI() async {
        openAITestState = .testing
        let key = openAIKey
        guard !key.isEmpty else {
            openAITestState = .idle
            return
        }
        guard let url = URL(string: "https://api.openai.com/v1/models") else {
            openAITestState = .failure("Invalid URL")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            openAITestState = status == 200 ? .success : .failure("HTTP \(status)")
        } catch {
            openAITestState = .failure(error.localizedDescription)
        }
    }

    private func testGemini() async {
        geminiTestState = .testing
        let key = geminiKey
        guard !key.isEmpty else {
            geminiTestState = .idle
            return
        }
        guard
            let escaped = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
            let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(escaped)")
        else {
            geminiTestState = .failure("Invalid URL")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            geminiTestState = status == 200 ? .success : .failure("HTTP \(status)")
        } catch {
            geminiTestState = .failure(error.localizedDescription)
        }
    }
}

#Preview {
    SettingsView()
        .modelContainer(for: [Project.self, Tab.self, AppSettings.self], inMemory: true)
}
