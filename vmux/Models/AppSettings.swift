import Foundation
import SwiftData

@Model
final class AppSettings {
    var displayName: String
    var openAIKeychainRef: String
    var geminiKeychainRef: String
    var geminiModel: String
    var activePanoramaFilename: String?
    var idleThresholdSeconds: Int

    init(
        displayName: String = "",
        openAIKeychainRef: String = "",
        geminiKeychainRef: String = "",
        geminiModel: String = "gemini-2.5-flash",
        activePanoramaFilename: String? = nil,
        idleThresholdSeconds: Int = 3
    ) {
        self.displayName = displayName
        self.openAIKeychainRef = openAIKeychainRef
        self.geminiKeychainRef = geminiKeychainRef
        self.geminiModel = geminiModel
        self.activePanoramaFilename = activePanoramaFilename
        self.idleThresholdSeconds = idleThresholdSeconds
    }

    @MainActor
    static func bootstrap(in context: ModelContext) throws {
        let descriptor = FetchDescriptor<AppSettings>()
        let existing = try context.fetch(descriptor)
        guard existing.isEmpty else { return }
        context.insert(AppSettings())
        try context.save()
    }
}
