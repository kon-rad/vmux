import XCTest
import SwiftData
@testable import vmux

@MainActor
final class ModelsTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: Project.self, Tab.self, AppSettings.self,
            configurations: config
        )
    }

    private func makeProject() -> Project {
        Project(
            name: "demo",
            host: "example.com",
            username: "alice",
            authType: "password",
            keychainRef: UUID().uuidString
        )
    }

    func testProjectAndTabRoundTrip() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let project = makeProject()
        context.insert(project)

        let tab = Tab(title: "Tab 1", project: project)
        context.insert(tab)
        try context.save()

        let projects = try context.fetch(FetchDescriptor<Project>())
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.tabs.count, 1)
        XCTAssertEqual(projects.first?.tabs.first?.title, "Tab 1")
    }

    func testCascadeDeleteRemovesChildTabs() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let project = makeProject()
        context.insert(project)
        context.insert(Tab(title: "Tab 1", project: project))
        context.insert(Tab(title: "Tab 2", project: project))
        try context.save()

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Tab>()), 2)

        context.delete(project)
        try context.save()

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Project>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Tab>()), 0,
                       "Cascade delete should remove child tabs")
    }

    func testBootstrapCreatesSingleAppSettingsRow() throws {
        let container = try makeContainer()
        let context = container.mainContext

        try AppSettings.bootstrap(in: context)
        try AppSettings.bootstrap(in: context)

        let rows = try context.fetch(FetchDescriptor<AppSettings>())
        XCTAssertEqual(rows.count, 1)
        let settings = try XCTUnwrap(rows.first)
        XCTAssertEqual(settings.displayName, "")
        XCTAssertEqual(settings.openAIKeychainRef, "")
        XCTAssertEqual(settings.geminiKeychainRef, "")
        XCTAssertEqual(settings.geminiModel, "gemini-2.5-flash")
        XCTAssertNil(settings.activePanoramaFilename)
        XCTAssertEqual(settings.idleThresholdSeconds, 3)
    }
}
