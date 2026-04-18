import AppKit
import SwiftUI

/// A floating panel that appears below the notch wing when clicked.
/// Separate from NotchWindow so it can extend below the menu bar.
final class DropdownWindow: NSPanel {

    private let wingFrame: NSRect
    private var globalMonitor: Any?

    init(wingFrame: NSRect) {
        self.wingFrame = wingFrame

        let dropdownWidth: CGFloat = 200
        let dropdownX = wingFrame.origin.x
        let dropdownY = wingFrame.origin.y - 400

        super.init(
            contentRect: NSRect(x: dropdownX, y: dropdownY, width: dropdownWidth, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configure()
    }

    private func configure() {
        isOpaque             = false
        backgroundColor      = .clear
        hasShadow            = true
        isMovable            = false
        isReleasedWhenClosed = false
        level                = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) - 1)
        collectionBehavior   = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        appearance           = NSAppearance(named: .darkAqua)
    }

    func present(onDismiss: @escaping () -> Void) {
        let content = DropdownPanelView(onDismiss: onDismiss)
            .environmentObject(ProviderRegistry.shared)

        let hostingView = NSHostingView(rootView: content)
        hostingView.sizingOptions = []
        contentView = hostingView

        hostingView.layout()
        let fittingSize = hostingView.fittingSize
        let w = max(fittingSize.width, 200)
        let h = max(fittingSize.height, 60)

        let newFrame = NSRect(
            x: wingFrame.origin.x,
            y: wingFrame.origin.y - h,
            width: w,
            height: h
        )
        setFrame(newFrame, display: false)
        hostingView.frame = CGRect(origin: .zero, size: CGSize(width: w, height: h))

        orderFrontRegardless()

        // Dismiss when user clicks outside both the dropdown AND the notch pill area.
        // The notch pill click is handled by NotchWindow.mouseUp which will close via toggleDropdown().
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return }
            // Use NSScreen coordinate: event.cgEvent?.location gives screen coords
            let screenPt = event.cgEvent.map { NSPoint(x: $0.location.x, y: $0.location.y) }
                           ?? NSPoint(x: event.locationInWindow.x, y: event.locationInWindow.y)

            // If click is inside the dropdown frame, let it pass through (interactive)
            if self.frame.contains(screenPt) { return }

            // If click is inside the notch pill (wingFrame), let NotchWindow handle toggle
            let notchRect = NSRect(
                x: self.wingFrame.origin.x,
                y: self.wingFrame.origin.y,
                width: self.wingFrame.width,
                height: self.wingFrame.height
            )
            if notchRect.contains(screenPt) { return }

            // Click is outside both — dismiss
            self.dismissWindow(onDismiss: onDismiss)
        }
    }

    func dismissWindow(onDismiss: @escaping () -> Void) {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        orderOut(nil)
        onDismiss()
    }

    override var canBecomeKey: Bool  { true  }
    override var canBecomeMain: Bool { false }
}
