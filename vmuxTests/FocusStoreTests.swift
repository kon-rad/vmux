import XCTest
@testable import vmux

@MainActor
final class FocusStoreTests: XCTestCase {

    func testInitialFocusIsNil() {
        let store = FocusStore()
        XCTAssertNil(store.focusedTabID)
    }

    func testHoverInSetsFocus() {
        let store = FocusStore()
        let tabA = UUID()
        store.reportHover(tabID: tabA, hovering: true)
        XCTAssertEqual(store.focusedTabID, tabA)
    }

    func testHoverOutDoesNotClearFocus() {
        // Sticky-focus invariant from T-015: only `hovering == true` writes.
        // A subsequent hover-out from the same window must NOT clear focus —
        // otherwise the speech coordinator would lose its target every time
        // the user glanced away briefly.
        let store = FocusStore()
        let tabA = UUID()
        store.reportHover(tabID: tabA, hovering: true)
        store.reportHover(tabID: tabA, hovering: false)
        XCTAssertEqual(store.focusedTabID, tabA)
    }

    func testHoverOnAnotherTabReplacesFocus() {
        let store = FocusStore()
        let tabA = UUID()
        let tabB = UUID()
        store.reportHover(tabID: tabA, hovering: true)
        store.reportHover(tabID: tabB, hovering: true)
        XCTAssertEqual(store.focusedTabID, tabB)
    }

    func testHoverOutFromOtherTabDoesNotClearFocus() {
        // Hover-out events from any tab must be ignored, including from a tab
        // that was never focused. Verifies the guard isn't checking identity.
        let store = FocusStore()
        let tabA = UUID()
        let tabB = UUID()
        store.reportHover(tabID: tabA, hovering: true)
        store.reportHover(tabID: tabB, hovering: false)
        XCTAssertEqual(store.focusedTabID, tabA)
    }
}
