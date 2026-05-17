import SwiftUI
import SwiftData

@main
struct vmuxApp: App {
    let container: ModelContainer

    init() {
        do {
            self.container = try ModelContainer(
                for: Project.self, Tab.self, AppSettings.self
            )
            try AppSettings.bootstrap(in: container.mainContext)
        } catch {
            fatalError("Failed to initialize SwiftData container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup(id: "sidebar") {
            SidebarView()
        }
        .modelContainer(container)

        WindowGroup(id: "settings") {
            SettingsView()
        }
        .modelContainer(container)

        WindowGroup(id: "terminal", for: UUID.self) { $tabID in
            if let tabID {
                TerminalWindowView(tabID: tabID)
            }
        }
        .modelContainer(container)

        ImmersiveSpace(id: "environment") {
            SkydomeView()
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
