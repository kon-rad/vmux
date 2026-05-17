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
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}

struct ContentView: View {
    var body: some View {
        Text("vmux")
            .font(.largeTitle)
            .padding()
    }
}

#Preview {
    ContentView()
}
