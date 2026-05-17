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

    @State private var panoramaPrompt: String = ""
    @State private var isGeneratingPanorama: Bool = false
    @State private var panoramaWarning: String?
    @State private var panoramaError: String?

    @State private var panoramaStore: PanoramaStore = .shared

    private let keychain = KeychainService()
    private let imageClient = OpenAIImageClient()

    private static let panoramaPromptLimit = 32_000

    var body: some View {
        NavigationStack {
            Form {
                profileSection
                openAISection
                geminiSection
                panoramaSection
                idleSection
            }
            .navigationTitle("Settings")
        }
        .frame(minWidth: 520, minHeight: 640)
        .onAppear(perform: loadFromStorage)
        .alert(
            "Panorama generation failed",
            isPresented: panoramaErrorPresented,
            actions: { Button("OK", role: .cancel) { panoramaError = nil } },
            message: { Text(panoramaError ?? "") }
        )
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

    private var panoramaSection: some View {
        Section("360 Environment") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Describe the panorama you want generated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: panoramaPromptBinding)
                    .frame(minHeight: 96, maxHeight: 200)
                    .textInputAutocapitalization(.sentences)
                    .overlay(alignment: .bottomTrailing) {
                        Text("\(panoramaPrompt.count) / \(Self.panoramaPromptLimit)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(4)
                    }
            }

            HStack {
                Button(action: { Task { await generatePanorama() } }) {
                    if isGeneratingPanorama {
                        ProgressView()
                    } else {
                        Text("Generate Panorama")
                    }
                }
                .disabled(!canGeneratePanorama)
                if openAIKey.isEmpty {
                    Text("Add an OpenAI key above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let warning = panoramaWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.black)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.yellow.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
            }

            PanoramaPickerGrid(store: panoramaStore) { filename in
                panoramaStore.setActive(filename: filename)
                settings.activePanoramaFilename = filename
            }
        }
    }

    private var canGeneratePanorama: Bool {
        !openAIKey.isEmpty
            && !isGeneratingPanorama
            && !panoramaPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var panoramaPromptBinding: Binding<String> {
        Binding(
            get: { panoramaPrompt },
            set: { newValue in
                if newValue.count > Self.panoramaPromptLimit {
                    panoramaPrompt = String(newValue.prefix(Self.panoramaPromptLimit))
                } else {
                    panoramaPrompt = newValue
                }
            }
        )
    }

    private var panoramaErrorPresented: Binding<Bool> {
        Binding(
            get: { panoramaError != nil },
            set: { presented in if !presented { panoramaError = nil } }
        )
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
        if panoramaStore.activeFilename != settings.activePanoramaFilename {
            panoramaStore.setActive(filename: settings.activePanoramaFilename)
        }
    }

    private func generatePanorama() async {
        let prompt = panoramaPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = openAIKey
        guard !prompt.isEmpty, !key.isEmpty else { return }
        isGeneratingPanorama = true
        panoramaWarning = nil
        panoramaError = nil
        defer { isGeneratingPanorama = false }
        do {
            let result = try await imageClient.generatePanorama(prompt: prompt, apiKey: key)
            let filename = try panoramaStore.save(pngBytes: result.pngBytes)
            panoramaStore.setActive(filename: filename)
            settings.activePanoramaFilename = filename
            panoramaWarning = result.warning
        } catch let error as OpenAIImageClientError {
            panoramaError = describe(error)
        } catch {
            panoramaError = error.localizedDescription
        }
    }

    private func describe(_ error: OpenAIImageClientError) -> String {
        switch error {
        case .invalidResponse:
            return "Invalid response from OpenAI."
        case .http(let status, let message):
            return "HTTP \(status): \(message)"
        case .missingImageData:
            return "OpenAI returned no image data."
        case .base64DecodeFailed:
            return "Could not decode the returned image."
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
