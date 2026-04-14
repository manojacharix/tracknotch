import AppKit
import SwiftUI

/// The slim 37pt wing window that sits permanently beside the notch.
/// Owns a DropdownWindow child that appears/disappears below it on click.
final class NotchWindow: NSPanel {

    let targetScreen: NSScreen
    let mode: NotchMode
    private var dropdownWindow: DropdownWindow?
    private(set) var isDropdownVisible = false

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

        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)))

        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]

        appearance = NSAppearance(named: .darkAqua)
    }

    private func setContent() {
        let rootView = NotchRootView(mode: mode, onToggleDropdown: { [weak self] in
            self?.toggleDropdown()
        })
        .environmentObject(ProviderRegistry.shared)
        .environmentObject(AppSettings.shared)
        .frame(width: mode.windowFrame.width, height: mode.windowFrame.height, alignment: .leading)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        hostingView.frame = CGRect(
            origin: .zero,
            size: CGSize(width: mode.windowFrame.width, height: mode.windowFrame.height)
        )
        contentView = hostingView
    }

    // MARK: - Dropdown

    func toggleDropdown() {
        if isDropdownVisible {
            closeDropdown()
        } else {
            openDropdown()
        }
    }

    private func openDropdown() {
        isDropdownVisible = true
        let dropdown = DropdownWindow(wingFrame: mode.windowFrame)
        dropdown.present(onDismiss: { [weak self] in
            self?.isDropdownVisible = false
            self?.dropdownWindow = nil
        })
        dropdownWindow = dropdown
        addChildWindow(dropdown, ordered: .below)
    }

    private func closeDropdown() {
        dropdownWindow?.dismissWindow(onDismiss: { [weak self] in
            self?.isDropdownVisible = false
            self?.dropdownWindow = nil
        })
    }

    // MARK: - Public

    func show() {
        setFrame(mode.windowFrame, display: true)
        orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in
            self?.orderFrontRegardless()
        }
    }

    // MARK: - Overrides

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
