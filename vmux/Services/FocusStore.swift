import Foundation
import Observation

/// Source of truth for "which terminal window is the user looking at right now"
/// (T-015). Updated by `TerminalWindowView.onHover` — visionOS reports `hovering
/// == true` when the user's gaze lands on the window. Focus is **sticky**: we
/// only overwrite `focusedTabID` when another tab reports gaze, never on
/// hover-out, so `SpeechCoordinator` (T-016b) has a stable target to bind to
/// between glances.
@MainActor
@Observable
final class FocusStore {
    static let shared = FocusStore()

    var focusedTabID: UUID?

    init(focusedTabID: UUID? = nil) {
        self.focusedTabID = focusedTabID
    }

    /// Called by `TerminalWindowView.onHover`. Only `hovering == true` writes;
    /// hover-out is intentionally ignored to keep focus sticky.
    func reportHover(tabID: UUID, hovering: Bool) {
        guard hovering else { return }
        focusedTabID = tabID
    }
}
