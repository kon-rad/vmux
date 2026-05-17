import Foundation
import SwiftData

@Model
final class Tab {
    @Attribute(.unique) var id: UUID
    var title: String
    var project: Project?
    var lastActivityAt: Date
    var isRunning: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        project: Project? = nil,
        lastActivityAt: Date = Date(),
        isRunning: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.project = project
        self.lastActivityAt = lastActivityAt
        self.isRunning = isRunning
        self.createdAt = createdAt
    }
}
