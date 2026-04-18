import AppKit
import SwiftUI

// MARK: - Strip click panel

/// Invisible panel sized exactly to the notch strip. Receives clicks and passes
/// everything else through. No Accessibility permission needed.
private final class StripPanel: NSPanel {

    var onNotchClick: (() -> Void)?

    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque             = false
        backgroundColor      = .clear
        hasShadow            = false
        isMovable            = false
        isReleasedWhenClosed = false
        level                = .mainMenu + 3
        ignoresMouseEvents   = false
        collectionBehavior   = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        contentView          = StripView()
        (contentView as? StripView)?.onNotchClick = { [weak self] in self?.onNotchClick?() }
    }

    override var canBecomeKey: Bool  { false }
    override var canBecomeMain: Bool { false }
}

private final class StripView: NSView {
    var onNotchClick: (() -> Void)?

    override func mouseUp(with event: NSEvent) { onNotchClick?() }
    override var acceptsFirstResponder: Bool   { true }
    override var mouseDownCanMoveWindow: Bool  { false }

    // Accept every point — the window is already strip-sized
    override func hitTest(_ point: NSPoint) -> NSView? { self }
}

// MARK: - NotchWindow

/// Large panel covering the full notch + wing area — display only, fully click-through.
/// A separate StripPanel (notch-height only) sits on top to receive clicks.
final class NotchWindow: NSPanel {

    let targetScreen: NSScreen
    let mode: NotchMode
    private(set) var isDropdownVisible = false
    private var dropdownWindow: DropdownWindow?
    private var stripPanel: StripPanel?
    private var externalClickMonitor: Any?

    init(screen: NSScreen, mode: NotchMode) {
        self.targetScreen = screen
        self.mode         = mode

        let initialFrame = mode.isExternal
            ? externalPanelFrame(screen: screen)
            : notchPanelFrame(screen: screen)

        super.init(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configure()
        setContent()
        if mode.isExternal {
            installExternalClickMonitor()
        } else {
            installStripPanel()
        }
    }

    // MARK: - Configuration

    private func configure() {
        isFloatingPanel            = true
        isOpaque                   = false
        backgroundColor            = .clear
        hasShadow                  = false
        isMovable                  = false
        isReleasedWhenClosed       = false
        titleVisibility            = .hidden
        titlebarAppearsTransparent = true
        level                      = .mainMenu + 3
        appearance                 = NSAppearance(named: .darkAqua)
        acceptsMouseMovedEvents    = false
        ignoresMouseEvents         = true   // render-only; StripPanel handles clicks

        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
    }

    private func setContent() {
        let hostingView: NSHostingView<AnyView>

        if mode.isExternal {
            let view = AnyView(
                ExternalMonitorView()
                    .environmentObject(ProviderRegistry.shared)
                    .allowsHitTesting(false)
            )
            hostingView = NSHostingView(rootView: view)
        } else {
            let view = AnyView(
                NotchRootView(mode: mode, onToggleDropdown: { [weak self] in self?.toggleDropdown() })
                    .environmentObject(ProviderRegistry.shared)
                    .environmentObject(AppSettings.shared)
                    .allowsHitTesting(false)
            )
            hostingView = NSHostingView(rootView: view)
        }

        hostingView.wantsLayer = true
        hostingView.layer?.masksToBounds = false
        contentView = hostingView
        contentView?.wantsLayer = true
        contentView?.layer?.masksToBounds = false
    }

    /// For external monitor mode: global monitor checks if click lands in the pill rect.
    /// The window stays fully click-through; we just observe and react.
    private func installExternalClickMonitor() {
        externalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let cg = event.cgEvent else { return }
            let pt = NSPoint(x: cg.location.x, y: cg.location.y)
            guard self.frame.contains(pt) else { return }
            // Only toggle if providers are active (pill is visible)
            guard !ProviderRegistry.shared.activeProviders.isEmpty else { return }
            DispatchQueue.main.async {
                self.haptic()
                self.toggleDropdown()
            }
        }
    }

    private func installStripPanel() {
        let strip = StripPanel(frame: stripRect)
        strip.onNotchClick = { [weak self] in
            self?.haptic()
            self?.toggleDropdown()
        }
        strip.orderFrontRegardless()
        stripPanel = strip
    }

    override func close() {
        stripPanel?.close()
        stripPanel = nil
        if let m = externalClickMonitor { NSEvent.removeMonitor(m); externalClickMonitor = nil }
        closeDropdown()
        super.close()
    }

    // MARK: - Strip rect (screen coordinates, notch height only)

    private var stripRect: NSRect {
        let sf          = targetScreen.frame
        let stripHeight = getNotchBlockSize(screen: targetScreen).height + 4
        return NSRect(
            x: frame.origin.x,
            y: sf.origin.y + sf.height - stripHeight,
            width: frame.width,
            height: stripHeight
        )
    }

    // MARK: - Haptic

    private func haptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(
            .levelChange,
            performanceTime: .now
        )
    }

    // MARK: - Dropdown

    func toggleDropdown() {
        isDropdownVisible ? closeDropdown() : openDropdown()
    }

    private func openDropdown() {
        isDropdownVisible = true
        let sf    = targetScreen.frame
        let dw: CGFloat = 280
        let dh: CGFloat = 400
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
        let frame = mode.isExternal
            ? externalPanelFrame(screen: targetScreen)
            : notchPanelFrame(screen: targetScreen)
        setFrame(frame, display: true)
        stripPanel?.setFrame(stripRect, display: true)
        orderFrontRegardless()
        stripPanel?.orderFrontRegardless()
    }

    override var canBecomeKey: Bool          { false }
    override var canBecomeMain: Bool         { false }
    override var acceptsFirstResponder: Bool { false }
}
