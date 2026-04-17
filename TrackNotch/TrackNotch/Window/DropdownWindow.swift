import AppKit
import SwiftUI

/// A floating panel that appears below the notch wing when clicked.
/// Separate from NotchWindow so it can extend below the menu bar.
final class DropdownWindow: NSPanel {

    private let wingFrame: NSRect

    init(wingFrame: NSRect) {
        self.wingFrame = wingFrame

        let dropdownWidth: CGFloat = 200
        let dropdownX = wingFrame.origin.x  // aligns with left edge of wing
        // Position below the wing (subtract height because macOS y=0 is bottom)
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
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) - 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua)
    }

    func present(onDismiss: @escaping () -> Void) {
        let content = DropdownPanelView(onDismiss: onDismiss)
            .environmentObject(ProviderRegistry.shared)

        let hostingView = NSHostingView(rootView: content)
        hostingView.sizingOptions = []
        contentView = hostingView

        // Size window to fit content
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

        // Dismiss on click outside
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismissWindow(onDismiss: onDismiss)
        }
    }

    func dismissWindow(onDismiss: @escaping () -> Void) {
        withAnimation {
            orderOut(nil)
        }
        onDismiss()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
