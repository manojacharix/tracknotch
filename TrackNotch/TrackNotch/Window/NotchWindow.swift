import AppKit
import SwiftUI

/// Single large panel centered on the screen top, covering the full notch + wing area.
/// Mirrors agentnotch's NotchPanel approach.
final class NotchWindow: NSPanel {

    let targetScreen: NSScreen
    let mode: NotchMode
    private(set) var isDropdownVisible = false
    private var dropdownWindow: DropdownWindow?

    init(screen: NSScreen, mode: NotchMode) {
        self.targetScreen = screen
        self.mode         = mode

        super.init(
            contentRect: notchPanelFrame(screen: screen),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configure()
        setContent()
    }

    // MARK: - Configuration

    private func configure() {
        isFloatingPanel           = true
        isOpaque                  = false
        backgroundColor           = .clear
        hasShadow                 = false
        isMovable                 = false
        isReleasedWhenClosed      = false
        titleVisibility           = .hidden
        titlebarAppearsTransparent = true
        level                     = .mainMenu + 3
        appearance                = NSAppearance(named: .darkAqua)

        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
    }

    private func setContent() {
        let rootView = NotchRootView(mode: mode, onToggleDropdown: { [weak self] in
            self?.toggleDropdown()
        })
        .environmentObject(ProviderRegistry.shared)
        .environmentObject(AppSettings.shared)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.masksToBounds = false
        contentView = hostingView
        contentView?.wantsLayer = true
        contentView?.layer?.masksToBounds = false
    }

    // MARK: - Dropdown

    func toggleDropdown() {
        isDropdownVisible ? closeDropdown() : openDropdown()
    }

    private func openDropdown() {
        isDropdownVisible = true
        let sf     = targetScreen.frame
        let dw: CGFloat = 280
        let dh: CGFloat = 400
        // Center dropdown under the notch
        let dx = sf.origin.x + (sf.width - dw) / 2
        let dy = sf.origin.y + sf.height - getNotchBlockSize(screen: targetScreen).height - dh

        let dropdown = DropdownWindow(wingFrame: NSRect(x: dx, y: dy + dh, width: dw, height: 37))
        dropdown.present(onDismiss: { [weak self] in
            self?.isDropdownVisible = false
            self?.dropdownWindow    = nil
        })
        dropdownWindow = dropdown
        addChildWindow(dropdown, ordered: .below)
    }

    private func closeDropdown() {
        dropdownWindow?.dismissWindow(onDismiss: { [weak self] in
            self?.isDropdownVisible = false
            self?.dropdownWindow    = nil
        })
    }

    // MARK: - Public

    func show() {
        setFrame(notchPanelFrame(screen: targetScreen), display: true)
        orderFrontRegardless()
    }

    // Must allow becoming key so SwiftUI mouse gestures (onTapGesture) receive events.
    // nonactivatingPanel style still prevents the app from stealing foreground focus.
    override var canBecomeKey: Bool  { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }
}
