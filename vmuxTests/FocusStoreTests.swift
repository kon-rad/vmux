import XCTest
@testable import vmux

@MainActor
final class FocusStoreTests: XCTestCase {
    func test_initialState_isNil() {
        let store = FocusStore()
        XCTAssertNil(store.focusedTabID)
    }

    func test_setFocusedTabID_updatesValue() {
        let store = FocusStore()
        let id = UUID()
        store.focusedTabID = id
        XCTAssertEqual(store.focusedTabID, id)
    }

    func test_setFocusedTabID_overwritesWithDifferentID() {
        let store = FocusStore()
        let a = UUID()
        let b = UUID()
        store.focusedTabID = a
        store.focusedTabID = b
        XCTAssertEqual(store.focusedTabID, b)
    }

    /// Mirrors how `TerminalWindowView.onHover` updates the store: only set when
    /// `hovering == true`; hover-out is a no-op so focus is sticky.
    func test_stickyHoverSemantics_hoverOutDoesNotClear() {
        let store = FocusStore()
        let a = UUID()
        let b = UUID()

        applyHover(store: store, tabID: a, hovering: true)
        XCTAssertEqual(store.focusedTabID, a)

        applyHover(store: store, tabID: a, hovering: false)
        XCTAssertEqual(store.focusedTabID, a, "Hover-out must not clear focus")

        applyHover(store: store, tabID: b, hovering: true)
        XCTAssertEqual(store.focusedTabID, b, "Hover-in on another tab must move focus")

        applyHover(store: store, tabID: b, hovering: false)
        XCTAssertEqual(store.focusedTabID, b, "Hover-out of new tab still does not clear")
    }

    func test_sharedSingleton_isStable() {
        let first = FocusStore.shared
        let second = FocusStore.shared
        XCTAssertTrue(first === second)
    }

    private func applyHover(store: FocusStore, tabID: UUID, hovering: Bool) {
        if hovering {
            store.focusedTabID = tabID
        }
    }
}
