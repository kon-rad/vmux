import Foundation
import SwiftData

@Model
final class Project {
    @Attribute(.unique) var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var authType: String
    var keychainRef: String
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \Tab.project) var tabs: [Tab]

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        authType: String,
        keychainRef: String,
        createdAt: Date = Date(),
        tabs: [Tab] = []
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authType = authType
        self.keychainRef = keychainRef
        self.createdAt = createdAt
        self.tabs = tabs
    }
}
