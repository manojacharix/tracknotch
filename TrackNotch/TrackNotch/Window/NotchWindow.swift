import AppKit
import SwiftUI

/// The main window that renders either beside the hardware notch
/// or draws the full software notch shape on displays without one.
final class NotchWindow: NSPanel {

    let targetScreen: NSScreen
    let mode: NotchMode

    init(screen: NSScreen, mode: NotchMode) {
        self.targetScreen = screen
        self.mode = mode

        super.init(
            contentRect: mode.windowFrame,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        configure()
        setContent()
    }

    // MARK: - Configuration

    private func configure() {
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true

        // Sit above menu bar, below nothing
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) - 1)

        // Visible on all spaces, full screen included
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]

        // Force dark appearance to match menu bar
        appearance = NSAppearance(named: .darkAqua)
    }

    private func setContent() {
        let rootView = NotchRootView(mode: mode)
            .environmentObject(ProviderRegistry.shared)
            .environmentObject(AppSettings.shared)

        contentView = NSHostingView(rootView: rootView)
    }

    // MARK: - Public

    func show() {
        setFrame(mode.windowFrame, display: false)
        orderFrontRegardless()
    }

    // MARK: - Overrides

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
