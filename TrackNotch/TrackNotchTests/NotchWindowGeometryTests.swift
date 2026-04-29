import XCTest
@testable import TrackNotch

/// Pins down the geometry that broke the hover/click on 2026-04-29.
///
/// These tests do NOT spin up an NSWindow. Instead they exercise a pure
/// helper that mirrors the math inside `NotchWindow.hoverRect`. To keep
/// these tests honest, please move that helper out of `NotchWindow.swift`
/// (currently `private`) into a small struct so it can be tested directly.
///
/// Suggested refactor (do this when wiring the tests):
/// ```swift
/// // In a new file Window/PillGeometry.swift
/// struct PillGeometry {
///     let pillHeight: CGFloat = 32
///     let verticalHoverPadding: CGFloat = 4
///
///     func hoverRect(
///         in screenFrame: NSRect,
///         visibleFrameMaxY: CGFloat,
///         windowMidX: CGFloat,
///         iconCount: Int,
///         iconSize: CGFloat = 22,
///         iconGap: CGFloat = 8,
///         sidePad: CGFloat = 10
///     ) -> NSRect {
///         let count = CGFloat(max(iconCount, 1))
///         let pillWidth = count * iconSize + max(0, count - 1) * iconGap + sidePad * 2
///         let hitWidth = max(pillWidth + 16, 40)
///         let menuBarH = screenFrame.height - (visibleFrameMaxY - screenFrame.origin.y)
///         let pillTopY = screenFrame.origin.y + screenFrame.height - menuBarH
///         let hitHeight = pillHeight + verticalHoverPadding * 2
///         return NSRect(
///             x: windowMidX - hitWidth / 2,
///             y: pillTopY - pillHeight - verticalHoverPadding,
///             width: hitWidth,
///             height: hitHeight
///         )
///     }
/// }
/// ```
/// Then update `NotchWindow.hoverRect` to delegate to `PillGeometry()`.
final class NotchWindowGeometryTests: XCTestCase {

    // Standard 27" external monitor: 2560×1440 at origin (0,0); 24pt menu bar.
    private let screenFrame = NSRect(x: 0, y: 0, width: 2560, height: 1440)
    private let visibleMaxY: CGFloat = 1440 - 24    // menu bar = 24
    private let windowMidX: CGFloat = 1280

    func test_hoverRect_sitsBelowMenuBar_notInside() {
        let g = PillGeometry()
        let rect = g.hoverRect(
            in: screenFrame,
            visibleFrameMaxY: visibleMaxY,
            windowMidX: windowMidX,
            iconCount: 3
        )

        // Menu bar occupies y in [1416, 1440]. The pill must sit BELOW that — i.e.
        // its top edge is at the menu bar's bottom, and the rect extends downward.
        let menuBarBottom: CGFloat = 1416
        XCTAssertLessThanOrEqual(rect.maxY, menuBarBottom + g.verticalHoverPadding,
                                 "hover rect should not extend above the menu bar's bottom")
        XCTAssertGreaterThanOrEqual(rect.maxY, menuBarBottom - 0.001,
                                    "hover rect's top should reach the menu bar's bottom")
    }

    func test_hoverRect_height_is_pillHeight_plus_padding() {
        let g = PillGeometry()
        let rect = g.hoverRect(
            in: screenFrame,
            visibleFrameMaxY: visibleMaxY,
            windowMidX: windowMidX,
            iconCount: 1
        )
        XCTAssertEqual(rect.height, g.pillHeight + g.verticalHoverPadding * 2, accuracy: 0.001)
    }

    func test_hoverRect_centeredOnWindowMidX() {
        let g = PillGeometry()
        let rect = g.hoverRect(
            in: screenFrame,
            visibleFrameMaxY: visibleMaxY,
            windowMidX: windowMidX,
            iconCount: 5
        )
        XCTAssertEqual(rect.midX, windowMidX, accuracy: 0.001)
    }

    func test_hoverRect_width_growsWithIconCount() {
        let g = PillGeometry()
        let one = g.hoverRect(in: screenFrame, visibleFrameMaxY: visibleMaxY, windowMidX: windowMidX, iconCount: 1).width
        let four = g.hoverRect(in: screenFrame, visibleFrameMaxY: visibleMaxY, windowMidX: windowMidX, iconCount: 4).width
        XCTAssertGreaterThan(four, one)
    }

    func test_hoverRect_minimumWidth_floor() {
        let g = PillGeometry()
        let rect = g.hoverRect(in: screenFrame, visibleFrameMaxY: visibleMaxY, windowMidX: windowMidX, iconCount: 0)
        XCTAssertGreaterThanOrEqual(rect.width, 40, "hit width has a floor for the dot state")
    }

    // TODO(sonnet):
    // - Once PillGeometry is extracted, delete the duplicate struct below and
    //   `import` from the main target. Until then, keep these in sync.
    // - Add a parameterised test across (notched MacBook, 24" external, 32" 4K, retina built-in)
    //   covering origin offsets when the external is to the LEFT of the primary
    //   (negative origin.x).
    // - Property test: rect.midX must equal windowMidX for any iconCount in 0...12.
}

// MARK: - Local copy of PillGeometry until the production type is extracted.
//
// DELETE THIS once `Window/PillGeometry.swift` exists in the main target.
struct PillGeometry {
    let pillHeight: CGFloat = 32
    let verticalHoverPadding: CGFloat = 4

    func hoverRect(
        in screenFrame: NSRect,
        visibleFrameMaxY: CGFloat,
        windowMidX: CGFloat,
        iconCount: Int,
        iconSize: CGFloat = 22,
        iconGap: CGFloat = 8,
        sidePad: CGFloat = 10
    ) -> NSRect {
        let count = CGFloat(max(iconCount, 1))
        let pillWidth = count * iconSize + max(0, count - 1) * iconGap + sidePad * 2
        let hitWidth = max(pillWidth + 16, 40)
        let menuBarH = screenFrame.height - (visibleFrameMaxY - screenFrame.origin.y)
        let pillTopY = screenFrame.origin.y + screenFrame.height - menuBarH
        let hitHeight = pillHeight + verticalHoverPadding * 2
        return NSRect(
            x: windowMidX - hitWidth / 2,
            y: pillTopY - pillHeight - verticalHoverPadding,
            width: hitWidth,
            height: hitHeight
        )
    }
}
