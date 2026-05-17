import Foundation

/// Source of truth for "which terminal tab is the user currently looking at".
///
/// Updated by `TerminalWindowView.onHover` and observed by `SpeechCoordinator`
/// (T-016b) to bind the active Gemini Live session to a specific tab.
///
/// Focus is **sticky**: `.onHover { hovering in if hovering { ... } }` only sets
/// the focus on hover-in. Hover-out does not clear it — the only way `focusedTabID`
/// changes is when another tab is hovered (or it's reset explicitly).
@MainActor
@Observable
final class FocusStore {
    static let shared = FocusStore()

    var focusedTabID: UUID?

    init() {}
}
