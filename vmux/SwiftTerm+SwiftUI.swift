import SwiftUI
import SwiftTerm
import UIKit

/// Embeds the session-owned `TerminalView` directly into SwiftUI. We don't
/// create a new `TerminalView` here because the session owns one whose
/// underlying `Terminal` is already being fed from the SSH pump. Embedding the
/// session's view keeps a single source of truth.
struct SwiftTermView: UIViewRepresentable {
    let session: TerminalSession

    func makeUIView(context: Context) -> TerminalView {
        return session.terminalView
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}
}
