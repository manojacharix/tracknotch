import AppKit

/// Determines which rendering mode to use for a given screen.
enum NotchMode {
    /// MacBook with a physical notch — app renders wings beside the cutout
    case hardwareNotch(notchFrame: NSRect, leftWing: NSRect, rightWing: NSRect)

    /// No physical notch — app draws the full notch shape itself
    case softwareNotch(centerFrame: NSRect)

    // MARK: - Detection

    static func detect(for screen: NSScreen) -> NotchMode {
        if let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea,
           leftArea.width > 0, rightArea.width > 0 {

            // Physical notch exists — calculate its frame
            let screenFrame = screen.frame
            let notchWidth = screenFrame.width - leftArea.width - rightArea.width
            let notchHeight = max(leftArea.height, rightArea.height, 37)
            let notchX = screenFrame.origin.x + leftArea.width
            let notchY = screenFrame.origin.y + screenFrame.height - notchHeight

            let notchFrame = NSRect(x: notchX, y: notchY, width: notchWidth, height: notchHeight)
            let leftWingFrame = NSRect(x: screenFrame.origin.x, y: notchY, width: leftArea.width, height: notchHeight)
            let rightWingFrame = NSRect(x: notchX + notchWidth, y: notchY, width: rightArea.width, height: notchHeight)

            return .hardwareNotch(notchFrame: notchFrame, leftWing: leftWingFrame, rightWing: rightWingFrame)
        }

        // No physical notch — use software notch
        let screenFrame = screen.frame
        let notchWidth: CGFloat = 126
        let notchHeight: CGFloat = 37
        let notchX = screenFrame.origin.x + (screenFrame.width - notchWidth) / 2
        let notchY = screenFrame.origin.y + screenFrame.height - notchHeight

        let centerFrame = NSRect(x: notchX, y: notchY, width: notchWidth, height: notchHeight)
        return .softwareNotch(centerFrame: centerFrame)
    }

    // MARK: - Helpers

    /// Frame for the right wing where app icons appear
    var rightWingFrame: NSRect {
        switch self {
        case .hardwareNotch(_, _, let rightWing):
            return rightWing
        case .softwareNotch(let center):
            // Right wing starts at right edge of software notch
            return NSRect(
                x: center.maxX,
                y: center.origin.y,
                width: 160,
                height: center.height
            )
        }
    }

    /// Frame for the full window (software notch needs to cover center + wing)
    var windowFrame: NSRect {
        switch self {
        case .hardwareNotch(_, _, let rightWing):
            return rightWing
        case .softwareNotch(let center):
            // Window covers both the drawn notch and the right wing
            return NSRect(
                x: center.origin.x,
                y: center.origin.y,
                width: center.width + 160,
                height: center.height
            )
        }
    }

    var isHardware: Bool {
        if case .hardwareNotch = self { return true }
        return false
    }
}
