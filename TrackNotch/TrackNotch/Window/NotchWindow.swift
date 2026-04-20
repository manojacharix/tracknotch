import AppKit
import SwiftUI

// MARK: - Strip click panel

/// Invisible panel sized exactly to the notch strip. Receives clicks and passes
/// everything else through. No Accessibility permission needed.
private final class StripPanel: NSPanel {

    var onNotchClick: (() -> Void)?
    var onHoverEnter: (() -> Void)?
    var onHoverExit:  (() -> Void)?

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
        let sv = StripView()
        sv.onNotchClick = { [weak self] in self?.onNotchClick?() }
        sv.onHoverEnter = { [weak self] in self?.onHoverEnter?() }
        sv.onHoverExit  = { [weak self] in self?.onHoverExit?() }
        contentView = sv
    }

    override var canBecomeKey: Bool  { false }
    override var canBecomeMain: Bool { false }
}

private final class StripView: NSView {
    var onNotchClick: (() -> Void)?
    var onHoverEnter: (() -> Void)?
    var onHoverExit:  (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingArea()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingArea()
    }

    private func updateTrackingArea() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { onHoverEnter?() }
    override func mouseExited(with event: NSEvent)  { onHoverExit?() }
    override func mouseUp(with event: NSEvent)      { onNotchClick?() }
    override var acceptsFirstResponder: Bool        { true }
    override var mouseDownCanMoveWindow: Bool       { false }

    override func hitTest(_ point: NSPoint) -> NSView? { self }
}

// MARK: - NotchWindow

/// Large panel covering the full notch + wing area — display only, fully click-through.
/// A separate StripPanel (notch-height only) sits on top to receive clicks.
final class NotchWindow: NSPanel {

    let targetScreen: NSScreen
    let mode: NotchMode
    private(set) var isDropdownVisible = false
    private var stripPanel: StripPanel?
    private var externalClickMonitor: Any?
    private var externalHoverMonitor: Any?
    private var hoverLeaveTimer: Timer?
    private var outsideClickMonitor: Any?

    /// Weak ref to the SwiftUI root so we can call open/closeExpanded()
    weak var rootViewController: NotchRootViewController?

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
                    .environmentObject(AppSettings.shared)
            )
            hostingView = NSHostingView(rootView: view)
        } else {
            let vc = NotchRootViewController(mode: mode, onToggleDropdown: { [weak self] in
                self?.toggleDropdown()
            })
            rootViewController = vc
            let view = AnyView(
                NotchRootView(mode: mode, onToggleDropdown: { [weak self] in
                    self?.toggleDropdown()
                })
                .environmentObject(ProviderRegistry.shared)
                .environmentObject(AppSettings.shared)
            )
            hostingView = NSHostingView(rootView: view)
        }

        hostingView.wantsLayer = true
        hostingView.layer?.masksToBounds = false
        contentView = hostingView
        contentView?.wantsLayer = true
        contentView?.layer?.masksToBounds = false
    }

    /// For external monitor mode: global monitors observe clicks and mouse movement.
    private func installExternalClickMonitor() {
        externalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let cg = event.cgEvent else { return }
            let primaryH = NSScreen.screens.first.map { $0.frame.height } ?? 0
            let appKitPt = NSPoint(x: cg.location.x, y: primaryH - cg.location.y)
            guard self.hoverRect.contains(appKitPt) else { return }
            let reg = ProviderRegistry.shared
            guard !reg.activeProviders.isEmpty || reg.isExternalHovered else { return }
            DispatchQueue.main.async {
                self.haptic()
                self.toggleDropdown()
            }
        }

        externalHoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self, let cg = event.cgEvent else { return }
            let primaryH = NSScreen.screens.first.map { $0.frame.height } ?? 0
            let appKitPt = NSPoint(x: cg.location.x, y: primaryH - cg.location.y)
            let inside = self.hoverRect.contains(appKitPt)
            DispatchQueue.main.async { self.updateHoverState(inside: inside) }
        }
    }

    private func updateHoverState(inside: Bool) {
        hoverLeaveTimer?.invalidate()
        hoverLeaveTimer = nil
        if inside {
            if !ProviderRegistry.shared.isExternalHovered { haptic() }
            ProviderRegistry.shared.isExternalHovered = true
        } else {
            hoverLeaveTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { _ in
                ProviderRegistry.shared.isExternalHovered = false
            }
        }
    }

    private func installStripPanel() {
        let strip = StripPanel(frame: stripRect)
        strip.onNotchClick = { [weak self] in
            self?.haptic()
            self?.toggleDropdown()
        }
        strip.onHoverEnter = { [weak self] in
            self?.haptic()
            ProviderRegistry.shared.isExternalHovered = true
        }
        strip.onHoverExit = {
            ProviderRegistry.shared.isExternalHovered = false
        }
        strip.orderFrontRegardless()
        stripPanel = strip
    }

    override func close() {
        stripPanel?.close()
        stripPanel = nil
        if let m = externalClickMonitor { NSEvent.removeMonitor(m); externalClickMonitor = nil }
        if let m = externalHoverMonitor { NSEvent.removeMonitor(m); externalHoverMonitor = nil }
        if let m = outsideClickMonitor  { NSEvent.removeMonitor(m); outsideClickMonitor  = nil }
        hoverLeaveTimer?.invalidate()
        hoverLeaveTimer = nil
        ProviderRegistry.shared.isExternalHovered = false
        super.close()
    }

    // MARK: - Strip rect

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

    // MARK: - Hover rect (external mode)

    private let externalHoverWidth: CGFloat = 200

    private var hoverRect: NSRect {
        NSRect(
            x: frame.midX - externalHoverWidth / 2,
            y: frame.origin.y,
            width: externalHoverWidth,
            height: frame.height
        )
    }

    // MARK: - Haptic

    private func haptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    // MARK: - Dropdown (now expands in-place inside NotchWindow)

    func toggleDropdown() {
        isDropdownVisible ? closeDropdown() : openDropdown()
    }

    private func openDropdown() {
        isDropdownVisible = true

        // For external/notchless: grow window tall enough for dropdown
        if mode.isExternal {
            let sf = targetScreen.frame
            let expandedH: CGFloat = trackNotchWindowHeight
            let newFrame = NSRect(
                x: frame.origin.x,
                y: sf.origin.y + sf.height - expandedH,
                width: frame.width,
                height: expandedH
            )
            setFrame(newFrame, display: true)
        }

        // Allow hit-testing and make key so SwiftUI buttons fire correctly
        ignoresMouseEvents = false
        stripPanel?.ignoresMouseEvents = true
        makeKeyAndOrderFront(nil)

        // Tell SwiftUI view to expand
        NotificationCenter.default.post(name: .notchExpandDropdown, object: nil)

        // Dismiss when user clicks outside the notch panel.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let cg = event.cgEvent else { return }
            let screenH = NSScreen.screens.first.map { $0.frame.height } ?? 0
            let appKitPt = NSPoint(x: cg.location.x, y: screenH - cg.location.y)
            if !self.frame.contains(appKitPt) {
                DispatchQueue.main.async { self.closeDropdown() }
            }
        }
    }

    private func closeDropdown() {
        isDropdownVisible = false
        ignoresMouseEvents = true
        stripPanel?.ignoresMouseEvents = false
        if isKeyWindow { resignKey() }

        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }

        NotificationCenter.default.post(name: .notchCollapseDropdown, object: nil)

        // For external/notchless: shrink window back to original size
        if mode.isExternal {
            let smallFrame = externalPanelFrame(screen: targetScreen)
            setFrame(smallFrame, display: true)
        }
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

    override var canBecomeKey: Bool          { isDropdownVisible }
    override var canBecomeMain: Bool         { false }
    override var acceptsFirstResponder: Bool { isDropdownVisible }
}

// MARK: - Notification names

extension Notification.Name {
    static let notchExpandDropdown   = Notification.Name("notchExpandDropdown")
    static let notchCollapseDropdown = Notification.Name("notchCollapseDropdown")
}

// MARK: - Thin VC shim (unused — kept for potential future imperative access)

final class NotchRootViewController {
    let mode: NotchMode
    let onToggleDropdown: () -> Void
    init(mode: NotchMode, onToggleDropdown: @escaping () -> Void) {
        self.mode = mode
        self.onToggleDropdown = onToggleDropdown
    }
}
