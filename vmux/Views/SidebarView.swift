import SwiftUI

struct SidebarView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    @State private var environmentOpen = false

    var body: some View {
        VStack(spacing: 16) {
            Text("vmux")
                .font(.largeTitle)

            Text("Sidebar (placeholder)")
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                Button("Open Settings") {
                    openWindow(id: "settings")
                }

                Button("Open Terminal") {
                    openWindow(id: "terminal", value: UUID())
                }

                Button("Toggle Environment") {
                    Task {
                        if environmentOpen {
                            await dismissImmersiveSpace()
                            environmentOpen = false
                        } else {
                            switch await openImmersiveSpace(id: "environment") {
                            case .opened:
                                environmentOpen = true
                            case .userCancelled, .error:
                                environmentOpen = false
                            @unknown default:
                                environmentOpen = false
                            }
                        }
                    }
                }
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .frame(minWidth: 320, minHeight: 480)
    }
}

#Preview {
    SidebarView()
}
