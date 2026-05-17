import SwiftUI

struct TerminalWindowView: View {
    let tabID: UUID

    var body: some View {
        VStack {
            Text("Terminal (placeholder)")
                .font(.title)
            Text(tabID.uuidString)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 640, minHeight: 400)
    }
}

#Preview {
    TerminalWindowView(tabID: UUID())
}
