import AppKit

/// Pure geometry helper for the external-monitor pill hit/hover rect.
///
/// Extracted from `NotchWindow.hoverRect` so the math can be tested
/// independently without an `NSWindow` or `NSScreen`.
struct PillGeometry {
    let pillHeight:           CGFloat = 32
    let verticalHoverPadding: CGFloat = 4

    func hoverRect(
        in screenFrame: NSRect,
        visibleFrameMaxY: CGFloat,
        windowMidX: CGFloat,
        iconCount: Int,
        iconSize: CGFloat = 22,
        iconGap:  CGFloat = 8,
        sidePad:  CGFloat = 10
    ) -> NSRect {
        let count     = CGFloat(max(iconCount, 1))
        let pillWidth = count * iconSize + max(0, count - 1) * iconGap + sidePad * 2
        let hitWidth  = max(pillWidth + 16, 40)
        let menuBarH  = screenFrame.height - (visibleFrameMaxY - screenFrame.origin.y)
        let pillTopY  = screenFrame.origin.y + screenFrame.height - menuBarH
        let hitHeight = pillHeight + verticalHoverPadding * 2
        return NSRect(
            x: windowMidX - hitWidth / 2,
            y: pillTopY - pillHeight - verticalHoverPadding,
            width: hitWidth,
            height: hitHeight
        )
    }
}
