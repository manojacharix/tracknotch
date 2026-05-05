import AppKit

/// Determines which rendering mode to use for a given screen.
/// Two variants only:
///   - hardwareNotch  — display with a physical notch (uses notch-hugging wings UI)
///   - external       — everything else: external monitors, notchless built-ins,
///                      and clamshell mode (uses floating dot/pill UI)
enum NotchMode {
    case hardwareNotch
    case external

    static func detect(for screen: NSScreen) -> NotchMode {
        if let left = screen.auxiliaryTopLeftArea, left.width > 0 { return .hardwareNotch }
        if screen.safeAreaInsets.top > 0 { return .hardwareNotch }
        return .external
    }

    var isHardware: Bool { self == .hardwareNotch }
    var isExternal: Bool { self == .external }
}

// MARK: - Sizing helpers (mirrors agentnotch NotchSizing)

let trackNotchWindowWidth: CGFloat  = 580
let trackNotchWindowHeight: CGFloat = 400
let trackNotchGlowPadding: CGFloat  = 24

/// The actual notch block size read from the screen (hardware or fallback).
@MainActor
func getNotchBlockSize(screen: NSScreen? = nil) -> CGSize {
    let s = screen ?? NSScreen.main
    var w: CGFloat = 200
    var h: CGFloat = 37

    if let screen = s {
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            w = screen.frame.width - l.width - r.width + 4
        }
        if screen.safeAreaInsets.top > 0 {
            h = screen.safeAreaInsets.top
        } else {
            let mb = screen.frame.maxY - screen.visibleFrame.maxY
            h = mb < 24 ? 37 : mb
        }
    }
    return CGSize(width: w, height: h + 2)
}

/// Geometry describing the notch and wing areas for layout.
struct NotchGeometry {
    let windowFrame: NSRect   // full panel frame
    let leftWingWidth: CGFloat   // space left of notch block
    let notchWidth: CGFloat      // physical notch block width
    let rightWingWidth: CGFloat  // space right of notch block
    let notchHeight: CGFloat
}

/// Compute the full panel frame and wing widths from screen geometry.
@MainActor
func notchGeometry(screen: NSScreen? = nil) -> NotchGeometry {
    guard let s = screen ?? NSScreen.main ?? NSScreen.screens.first else {
        return NotchGeometry(windowFrame: .zero, leftWingWidth: 0, notchWidth: 208, rightWingWidth: 0, notchHeight: 37)
    }
    let sf = s.frame

    // Physical notch block
    let leftAuxW  = s.auxiliaryTopLeftArea?.width  ?? (sf.width / 2 - 100)
    let rightAuxW = s.auxiliaryTopRightArea?.width ?? (sf.width / 2 - 100)
    let notchW    = sf.width - leftAuxW - rightAuxW
    var notchH: CGFloat = 37
    if s.safeAreaInsets.top > 0 { notchH = s.safeAreaInsets.top }

    // Wing widths — extend 200pt beyond notch on each side
    let wingW: CGFloat = 200
    let winX = sf.origin.x + leftAuxW - wingW
    let winW = wingW + notchW + wingW
    let winY = sf.origin.y + sf.height - trackNotchWindowHeight

    let frame = NSRect(x: winX, y: winY, width: winW, height: trackNotchWindowHeight)
    return NotchGeometry(
        windowFrame: frame,
        leftWingWidth: wingW,
        notchWidth: notchW,
        rightWingWidth: wingW,
        notchHeight: notchH + 2
    )
}

/// Backwards-compat helper used by NotchWindow.
@MainActor
func notchPanelFrame(screen: NSScreen? = nil) -> NSRect {
    notchGeometry(screen: screen).windowFrame
}

/// Frame for the external/notchless monitor panel.
/// Same height as notch panel so dropdown can expand within it.
let externalPanelWidth:  CGFloat = 600
let externalPanelHeight: CGFloat = 56  // legacy — kept for reference

@MainActor
func externalPanelFrame(screen: NSScreen) -> NSRect {
    let sf = screen.frame
    let x  = sf.origin.x + (sf.width - trackNotchWindowWidth) / 2
    let y  = sf.origin.y + sf.height - trackNotchWindowHeight
    return NSRect(x: x, y: y, width: trackNotchWindowWidth, height: trackNotchWindowHeight)
}

