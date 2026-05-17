import SwiftUI

@main
struct vmuxApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
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
