import AppKit
import SwiftUI
import Combine

// MARK: - WindowHoverState

/// Per-window hover state. One instance per NotchWindowBase subclass.
/// Passed into NotchRootView via environmentObject so each window's
/// hover signal is isolated — the hardware notch and external monitor
/// no longer share a global isExternalHovered flag.
final class WindowHoverState: ObservableObject {
    @Published var isHovered: Bool = false
    @Published var stripEnterCount: Int = 0
}

// MARK: - PassthroughHostingView (shared)

final class PassthroughHostingView: NSHostingView<AnyView> {
    var interactiveRectProvider: (() -> NSRect?)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let rect = interactiveRectProvider?() else { return nil }
        guard rect.contains(point) else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - NotchWindowBase

/// Shared base for HardwareNotchWindow and ExternalNotchWindow.
/// Owns: panel configuration, SwiftUI hosting, dropdown state machine,
/// outside-click monitor, frame reporter.
/// Does NOT own: strip panels, hover monitors, click monitors — those
/// belong to the subclasses.
class NotchWindowBase: NSPanel {

    let expandedWindowWidth:  CGFloat = 420
    let expandedWindowHeight: CGFloat = 280

    let targetScreen: NSScreen
    let mode: NotchMode

    private(set) var isDropdownVisible = false

    let frameReporter = DropdownFrameReporter()
    let hoverState = WindowHoverState()
    private var contentHeightCancellable: AnyCancellable?

    private var outsideClickMonitor: Any?
    private var collapseFinalizeWork: DispatchWorkItem?
    private var lastToggleTime: TimeInterval = 0

    weak var passthroughHostingView: PassthroughHostingView?

    // MARK: - Init

    init(screen: NSScreen, mode: NotchMode) {
        self.targetScreen = screen
        self.mode = mode
        let initialFrame = Self.collapsedFrame(for: screen, mode: mode)
        super.init(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configurePanel()
    }

    // MARK: - Panel configuration

    private func configurePanel() {
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
        ignoresMouseEvents         = true
        collectionBehavior = [
            .canJoinAllSpaces, .stationary,
            .fullScreenAuxiliary, .ignoresCycle,
        ]
    }

    // MARK: - Content installation (called by subclass after init)

    func installContent(_ view: AnyView) {
        let wrapped = AnyView(view.environmentObject(hoverState))
        let hostingView = PassthroughHostingView(rootView: wrapped)
        hostingView.interactiveRectProvider = { [weak self] in self?.interactiveContentRectInView }
        hostingView.wantsLayer = true
        hostingView.layer?.masksToBounds = false
        hostingView.layer?.drawsAsynchronously = true
        passthroughHostingView = hostingView
        contentView = hostingView
        contentView?.wantsLayer = true
        contentView?.layer?.masksToBounds = false
        contentView?.layer?.drawsAsynchronously = true
    }

    // MARK: - Frame geometry

    var collapsedFrame: NSRect { Self.collapsedFrame(for: targetScreen, mode: mode) }

    static func collapsedFrame(for screen: NSScreen, mode: NotchMode) -> NSRect {
        mode.isDrawnNotch ? externalPanelFrame(screen: screen) : notchPanelFrame(screen: screen)
    }

    var expandedFrame: NSRect {
        let collapsed = collapsedFrame
        let cx = collapsed.midX
        return NSRect(
            x: cx - expandedWindowWidth / 2,
            y: collapsed.maxY - expandedWindowHeight,
            width: expandedWindowWidth,
            height: expandedWindowHeight
        )
    }

    // MARK: - Interactive rect (hit-test while dropdown open)

    var interactiveContentRectInView: NSRect? {
        guard isDropdownVisible, let contentView else { return nil }
        let bounds = contentView.bounds
        let pillH: CGFloat = mode.isDrawnNotch
            ? 32
            : notchGeometry(screen: targetScreen).notchHeight
        let sideInset: CGFloat = 4
        let dropdownW: CGFloat = mode.isDrawnNotch
            ? min(380, targetScreen.frame.width - 40)
            : expandedWindowWidth
        let pillW: CGFloat = dropdownW - sideInset * 2
        let measured = frameReporter.dropdownContentHeight
        let contentH: CGFloat = measured > 0 ? measured : 200
        let totalH = pillH + contentH
        return NSRect(
            x: bounds.midX - pillW / 2,
            y: bounds.height - totalH,
            width: pillW,
            height: totalH
        )
    }

    // MARK: - Haptic

    func haptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    // MARK: - Dropdown toggle

    func toggleDropdown() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastToggleTime >= 0.2 else { return }
        lastToggleTime = now
        isDropdownVisible ? closeDropdown() : openDropdown()
    }

    // MARK: - Open / close

    func openDropdown() {
        collapseFinalizeWork?.cancel()
        collapseFinalizeWork = nil
        isDropdownVisible = true
        ignoresMouseEvents = false
        onDropdownWillOpen()

        NotificationCenter.default.post(name: .notchExpandDropdown, object: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            guard let self, self.isDropdownVisible else { return }
            let pillH: CGFloat = self.mode.isDrawnNotch
                ? 32
                : notchGeometry(screen: self.targetScreen).notchHeight
            let dropW: CGFloat = self.mode.isDrawnNotch
                ? min(380, self.targetScreen.frame.width - 40)
                : self.expandedWindowWidth
            let measured = self.frameReporter.dropdownContentHeight
            let contentH: CGFloat = measured > 0 ? measured : 200
            let totalH = pillH + contentH
            let collapsed = self.collapsedFrame
            let newFrame = NSRect(
                x: collapsed.midX - dropW / 2,
                y: collapsed.maxY - totalH,
                width: dropW,
                height: totalH
            )
            self.setFrame(newFrame, display: true, animate: false)
            self.frameReporter.panelFitsVisibleShape = true
            self.observeDropdownContentHeight()
        }

        installOutsideClickMonitor()
    }

    func closeDropdown(fromNotification: Bool = false) {
        isDropdownVisible = false
        collapseFinalizeWork?.cancel()
        collapseFinalizeWork = nil
        removeOutsideClickMonitor()
        contentHeightCancellable?.cancel()
        contentHeightCancellable = nil
        frameReporter.panelFitsVisibleShape = false
        setFrame(collapsedFrame, display: true, animate: false)

        if !fromNotification {
            NotificationCenter.default.post(name: .notchCollapseDropdown, object: nil)
        }

        ignoresMouseEvents = true
        onDropdownDidClose()
        if isKeyWindow { resignKey() }
    }

    // MARK: - Subclass hooks

    func onDropdownWillOpen() {}
    func onDropdownDidClose() {}
    func onShow() {}
    func onRefreshAfterWake() {}
    func onReposition() {}

    // MARK: - Outside-click monitor

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        let installTime = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.isDropdownVisible else { return }
            self.outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                guard let self, event.timestamp > installTime else { return }
                guard let cg = event.cgEvent else { return }
                let sf = self.targetScreen.frame
                let pt = NSPoint(x: cg.location.x, y: sf.origin.y + sf.height - cg.location.y)
                guard let interactive = self.interactiveContentRectInView else {
                    if !self.frame.contains(pt) {
                        DispatchQueue.main.async { self.closeDropdown() }
                    }
                    return
                }
                let visibleScreen = NSRect(
                    x: self.frame.origin.x + interactive.origin.x,
                    y: self.frame.origin.y + interactive.origin.y,
                    width: interactive.width,
                    height: interactive.height
                )
                if !visibleScreen.contains(pt) {
                    DispatchQueue.main.async { self.closeDropdown() }
                }
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
    }

    // MARK: - Content height observation

    private func observeDropdownContentHeight() {
        contentHeightCancellable?.cancel()
        contentHeightCancellable = frameReporter.$dropdownContentHeight
            .removeDuplicates()
            .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .sink { [weak self] h in
                guard let self, self.isDropdownVisible, h > 0 else { return }
                let pillH: CGFloat = self.mode.isDrawnNotch
                    ? 32
                    : notchGeometry(screen: self.targetScreen).notchHeight
                let dropW: CGFloat = self.mode.isDrawnNotch
                    ? min(380, self.targetScreen.frame.width - 40)
                    : self.expandedWindowWidth
                let totalH = pillH + h
                let collapsed = self.collapsedFrame
                let newFrame = NSRect(
                    x: collapsed.midX - dropW / 2,
                    y: collapsed.maxY - totalH,
                    width: dropW,
                    height: totalH
                )
                if !NSEqualRects(self.frame, newFrame) {
                    self.setFrame(newFrame, display: true, animate: false)
                }
            }
    }

    // MARK: - Public API

    func show() {
        isDropdownVisible = false
        ignoresMouseEvents = true
        setFrame(collapsedFrame, display: true)
        onShow()
        orderFrontRegardless()
    }

    func forceCollapseDropdownIfOpen() {
        guard isDropdownVisible else { return }
        closeDropdown()
    }

    func refreshAfterWake() {
        onRefreshAfterWake()
        hoverState.isHovered = false
        // Let the view reset its pill state (fixes stale full-width pill on wake)
        NotificationCenter.default.post(name: .notchRefreshAfterWake, object: nil)
    }

    func reposition(to screen: NSScreen) {
        setFrame(Self.collapsedFrame(for: screen, mode: mode), display: true)
        onReposition()
    }

    override func close() {
        removeOutsideClickMonitor()
        contentHeightCancellable?.cancel()
        super.close()
    }

    override var canBecomeKey: Bool          { isDropdownVisible }
    override var canBecomeMain: Bool         { false }
    override var acceptsFirstResponder: Bool { isDropdownVisible }
}

// MARK: - Notification names

extension Notification.Name {
    static let notchExpandDropdown   = Notification.Name("notchExpandDropdown")
    static let notchCollapseDropdown = Notification.Name("notchCollapseDropdown")
    static let notchRefreshAfterWake = Notification.Name("notchRefreshAfterWake")
}
