import AppKit
import SwiftUI

// MARK: - Strip click panel

private final class PassthroughHostingView: NSHostingView<AnyView> {
    var interactiveRectProvider: (() -> NSRect?)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only allow hits within the interactive rect (dropdown area).
        // Everything outside passes through to windows behind.
        guard let rect = interactiveRectProvider?() else {
            return nil
        }
        guard rect.contains(point) else {
            return nil
        }
        let result = super.hitTest(point)
        NSLog("[PassthroughHostingView] hitTest HIT at \(point), result=\(String(describing: result))")
        return result
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

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

    override func sendEvent(_ event: NSEvent) {
        // For mouse clicks, check if any subview claims the hit.
        // If not, temporarily become click-through for this event so it
        // falls through to windows and menu bar items behind the panel.
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            let pt = contentView?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            if contentView?.hitTest(pt) == nil {
                ignoresMouseEvents = true
                NSApp.postEvent(event, atStart: true)
                DispatchQueue.main.async { self.ignoresMouseEvents = false }
                return
            }
        }
        super.sendEvent(event)
    }
}

private final class StripView: NSView {
    var onNotchClick: (() -> Void)?
    var onHoverEnter: (() -> Void)?
    var onHoverExit:  (() -> Void)?
    /// Rect within bounds that accepts clicks. nil = full bounds.
    var clickableRect: NSRect?

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

    override func mouseEntered(with event: NSEvent) {
        NSLog("[StripView] mouseEntered")
        onHoverEnter?()
    }
    override func mouseExited(with event: NSEvent) {
        NSLog("[StripView] mouseExited")
        onHoverExit?()
    }
    override func mouseDown(with event: NSEvent) {
        NSLog("[StripView] mouseDown at \(event.locationInWindow)")
    }
    override func mouseUp(with event: NSEvent) {
        NSLog("[StripView] mouseUp at \(event.locationInWindow)")
        onNotchClick?()
    }
    override var acceptsFirstResponder: Bool        { true }
    override var mouseDownCanMoveWindow: Bool       { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if let r = clickableRect {
            return r.contains(point) ? self : nil
        }
        return self
    }
}

// MARK: - NotchWindow

/// Large panel covering the full notch + wing area — display only, fully click-through.
/// A separate StripPanel (notch-height only) sits on top to receive clicks.
final class NotchWindow: NSPanel {
    private let expandedWindowWidth: CGFloat = 380
    private let expandedWindowHeight: CGFloat = 280

    let targetScreen: NSScreen
    let mode: NotchMode
    private(set) var isDropdownVisible = false
    private var stripPanel: StripPanel?
    private weak var passthroughHostingView: PassthroughHostingView?
    private var externalClickMonitor: Any?
    private var externalHoverMonitor: Any?
    private var hoverLeaveTimer: Timer?
    private var outsideClickMonitor: Any?
    private var collapseFinalizeWork: DispatchWorkItem?

    init(screen: NSScreen, mode: NotchMode) {
        self.targetScreen = screen
        self.mode         = mode

        let initialFrame = Self.collapsedFrame(for: screen, mode: mode)

        super.init(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configure()
        setContent()
        if mode.isExternal {
            installExternalStripPanel()
            installExternalHoverMonitor()
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
        let hostingView: PassthroughHostingView

        if mode.isExternal {
            let view = AnyView(
                ExternalMonitorView()
                    .environmentObject(ProviderRegistry.shared)
                    .environmentObject(AppSettings.shared)
            )
            hostingView = PassthroughHostingView(rootView: view)
        } else {
            let view = AnyView(
                NotchRootView(mode: mode, onToggleDropdown: { [weak self] in
                    self?.toggleDropdown()
                })
                .environmentObject(ProviderRegistry.shared)
                .environmentObject(AppSettings.shared)
            )
            hostingView = PassthroughHostingView(rootView: view)
        }

        hostingView.interactiveRectProvider = { [weak self] in
            self?.interactiveContentRectInView
        }
        hostingView.wantsLayer = true
        hostingView.layer?.masksToBounds = false
        hostingView.layer?.drawsAsynchronously = true
        passthroughHostingView = hostingView
        contentView = hostingView
        contentView?.wantsLayer = true
        contentView?.layer?.masksToBounds = false
        contentView?.layer?.drawsAsynchronously = true
    }

    /// For external monitor mode: a StripPanel intercepts clicks (prevents pass-through
    /// to apps behind), and a global mouseMoved monitor handles dynamic hover detection.
    private var collapseObserver: Any?

    private func installExternalStripPanel() {
        let strip = StripPanel(frame: activeStripRect)
        strip.onNotchClick = { [weak self] in
            guard let self else { return }
            self.haptic()
            self.toggleDropdown()
        }
        strip.onHoverEnter = { [weak self] in
            self?.updateHoverState(inside: true)
        }
        strip.onHoverExit = { [weak self] in
            self?.updateHoverState(inside: false)
        }
        strip.orderFrontRegardless()
        stripPanel = strip

        // Listen for collapse from SwiftUI (ExternalMonitorView posts this directly)
        collapseObserver = NotificationCenter.default.addObserver(
            forName: .notchCollapseDropdown, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isDropdownVisible else { return }
            self.closeDropdown(fromNotification: true)
        }
    }

    private func installExternalHoverMonitor() {
        externalHoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self, let cg = event.cgEvent else { return }
            let primaryH = NSScreen.screens.first.map { $0.frame.height } ?? 0
            let appKitPt = NSPoint(x: cg.location.x, y: primaryH - cg.location.y)
            let inside = self.hoverRect.contains(appKitPt)
            DispatchQueue.main.async {
                self.updateHoverState(inside: inside)
                self.updateExternalStripFrame()
            }
        }
    }

    private func updateHoverState(inside: Bool) {
        hoverLeaveTimer?.invalidate()
        hoverLeaveTimer = nil
        if inside {
            if !ProviderRegistry.shared.isExternalHovered { haptic() }
            ProviderRegistry.shared.isExternalHovered = true
            updateExternalStripFrame()
        } else {
            hoverLeaveTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { _ in
                ProviderRegistry.shared.isExternalHovered = false
                self.updateExternalStripFrame()
            }
        }
    }

    /// Resizes the external StripPanel to match the current pill hover zone.
    private func updateExternalStripFrame() {
        guard mode.isExternal, let strip = stripPanel else { return }
        let newRect = hoverRect
        if strip.frame != newRect {
            strip.setFrame(newRect, display: true)
        }
    }

    private func installStripPanel() {
        let strip = StripPanel(frame: activeStripRect)
        strip.onNotchClick = { [weak self] in
            self?.haptic()
            self?.toggleDropdown()
        }
        strip.onHoverEnter = { [weak self] in
            self?.haptic()
            ProviderRegistry.shared.isExternalHovered = true
            self?.updateStripFrame()
        }
        strip.onHoverExit = { [weak self] in
            ProviderRegistry.shared.isExternalHovered = false
            self?.updateStripFrame()
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
        if let o = collapseObserver     { NotificationCenter.default.removeObserver(o); collapseObserver = nil }
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

    private var activeStripRect: NSRect {
        mode.isExternal ? hoverRect : hardwareStripRect
    }

    private static func collapsedFrame(for screen: NSScreen, mode: NotchMode) -> NSRect {
        mode.isExternal ? externalPanelFrame(screen: screen) : notchPanelFrame(screen: screen)
    }

    private var collapsedFrame: NSRect {
        Self.collapsedFrame(for: targetScreen, mode: mode)
    }

    private var expandedFrame: NSRect {
        let collapsed = collapsedFrame
        // Keep the same horizontal center as the collapsed notch frame
        // and pin the top edge to the same position (top of screen)
        let cx = collapsed.midX
        return NSRect(
            x: cx - expandedWindowWidth / 2,
            y: collapsed.maxY - expandedWindowHeight,
            width: expandedWindowWidth,
            height: expandedWindowHeight
        )
    }

    private var hardwareStripRect: NSRect {
        let geo = notchGeometry(screen: targetScreen)
        let base = stripRect

        let hovered = ProviderRegistry.shared.isExternalHovered
        let visibleProviders: [LLMProvider] = hovered || isDropdownVisible
            ? ProviderRegistry.shared.connectedProviders.filter { ProviderRegistry.shared.usageMap[$0] != nil }
            : ProviderRegistry.shared.activeProviders

        let leftCount = visibleProviders.filter { $0.notchWing == .left }.count
        let rightCount = visibleProviders.filter { $0.notchWing == .right }.count

        let leftWingWidth = isDropdownVisible ? 0 : renderedWingWidth(count: leftCount)
        let rightWingWidth = isDropdownVisible ? 0 : renderedWingWidth(count: rightCount)
        let contentWidth = isDropdownVisible ? 380 : max(geo.notchWidth, leftWingWidth + geo.notchWidth + rightWingWidth)
        let hitPadding: CGFloat = isDropdownVisible ? 0 : 6

        let x: CGFloat
        if isDropdownVisible {
            x = frame.midX - contentWidth / 2
        } else {
            x = frame.origin.x + geo.leftWingWidth - leftWingWidth
        }

        return NSRect(
            x: x - hitPadding,
            y: base.origin.y,
            width: contentWidth + hitPadding * 2,
            height: base.height
        )
    }

    private func renderedWingWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let iconSize: CGFloat = 22
        let iconGap: CGFloat = 8
        let outerSidePadding: CGFloat = 12
        let innerSidePadding: CGFloat = 10
        return CGFloat(count) * iconSize
            + CGFloat(count - 1) * iconGap
            + outerSidePadding
            + innerSidePadding
    }

    private func updateStripFrame() {
        guard let strip = stripPanel else { return }
        let newRect = activeStripRect
        if strip.frame != newRect {
            strip.setFrame(newRect, display: true)
        }
        // Limit click area to actual pill content (exclude padding used for hover)
        if let sv = strip.contentView as? StripView {
            let pad: CGFloat = isDropdownVisible ? 0 : 6
            sv.clickableRect = pad > 0
                ? NSRect(x: pad, y: 0, width: newRect.width - pad * 2, height: newRect.height)
                : nil
        }
    }

    private var interactiveContentRectInView: NSRect? {
        guard isDropdownVisible, let contentView else { return nil }
        // Only make the dropdown pill area interactive (centered, top-pinned).
        // The rest of the window passes clicks through to apps behind.
        let bounds = contentView.bounds
        let pillW: CGFloat = expandedWindowWidth
        let pillH: CGFloat = expandedWindowHeight
        let rect = NSRect(
            x: bounds.midX - pillW / 2,
            y: bounds.maxY - pillH,
            width: pillW,
            height: pillH
        )
        NSLog("[NotchWindow] interactiveRect=\(rect), bounds=\(bounds), isDropdownVisible=\(isDropdownVisible)")
        return rect
    }

    // MARK: - Hover rect (external mode)

    /// Dynamic hover/click zone: sized to the pill's actual width (icons + padding)
    /// plus generous margins so it's easy to target. Minimum 120px for the idle dot.
    private var hoverRect: NSRect {
        let registry = ProviderRegistry.shared
        let iconCount = CGFloat(max(
            registry.activeProviders.count,
            registry.isExternalHovered
                ? registry.connectedProviders.filter { registry.usageMap[$0] != nil }.count
                : 0
        ))
        let iconSize: CGFloat = 22
        let iconGap: CGFloat = 8
        let sidePad: CGFloat = 10
        let pillWidth: CGFloat = iconCount > 0
            ? iconCount * iconSize + max(0, iconCount - 1) * iconGap + sidePad * 2
            : 8
        // Add 40px margin on each side for comfortable targeting
        let hitWidth = max(pillWidth + 80, 120)
        let sf = targetScreen.frame
        let menuBarH = sf.height - (targetScreen.visibleFrame.maxY - sf.origin.y)
        return NSRect(
            x: frame.midX - hitWidth / 2,
            y: sf.origin.y + sf.height - menuBarH - 40,
            width: hitWidth,
            height: menuBarH + 40
        )
    }

    // MARK: - Haptic

    private func haptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    // MARK: - Dropdown (now expands in-place inside NotchWindow)

    func toggleDropdown() {
        NSLog("[NotchWindow] toggleDropdown: isDropdownVisible=\(isDropdownVisible)")
        isDropdownVisible ? closeDropdown() : openDropdown()
    }

    private func openDropdown() {
        NSLog("[NotchWindow] openDropdown called, frame=\(frame)")
        collapseFinalizeWork?.cancel()
        collapseFinalizeWork = nil
        isDropdownVisible = true

        // Allow hit-testing and make key so SwiftUI buttons fire correctly
        ignoresMouseEvents = false
        stripPanel?.ignoresMouseEvents = true
        updateStripFrame()
        makeKeyAndOrderFront(nil)
        NSLog("[NotchWindow] openDropdown: isKey=\(isKeyWindow), ignoresMouse=\(ignoresMouseEvents), stripIgnores=\(stripPanel?.ignoresMouseEvents ?? true)")

        // Tell SwiftUI view to expand
        NotificationCenter.default.post(name: .notchExpandDropdown, object: nil)

        // Install outside-click monitor after a short delay to avoid catching the
        // triggering mouseDown or any buffered prior clicks in the event queue.
        let installTime = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard self.isDropdownVisible else { return }
            self.outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self else { return }
                // Skip events that happened before the monitor was installed
                guard event.timestamp > installTime.timeIntervalSinceReferenceDate else { return }
                guard let cg = event.cgEvent else { return }
                let screenH = NSScreen.screens.first.map { $0.frame.height } ?? 0
                let appKitPt = NSPoint(x: cg.location.x, y: screenH - cg.location.y)
                if !self.frame.contains(appKitPt) {
                    DispatchQueue.main.async { self.closeDropdown() }
                }
            }
        }
    }

    private func closeDropdown(fromNotification: Bool = false) {
        NSLog("[NotchWindow] closeDropdown called (fromNotification=\(fromNotification))")
        isDropdownVisible = false
        collapseFinalizeWork?.cancel()
        collapseFinalizeWork = nil

        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }

        // Only post collapse notification if we're initiating the close
        // (not if SwiftUI already posted it and we're responding)
        if !fromNotification {
            NotificationCenter.default.post(name: .notchCollapseDropdown, object: nil)
        }

        // Restore click-through immediately and re-enable strip panel
        ignoresMouseEvents = true
        stripPanel?.ignoresMouseEvents = false
        updateStripFrame()
        if let strip = stripPanel {
            strip.order(.above, relativeTo: windowNumber)
            NSLog("[NotchWindow] closeDropdown: strip reordered, frame=\(strip.frame), ignoresMouse=\(strip.ignoresMouseEvents)")
        }
        // Resign key AFTER reordering to prevent macOS from shuffling windows
        if isKeyWindow { resignKey() }
        NSLog("[NotchWindow] closeDropdown done: notchWindow.ignoresMouse=\(ignoresMouseEvents), stripPanel.ignoresMouse=\(stripPanel?.ignoresMouseEvents ?? true)")
    }

    // MARK: - Public

    func show() {
        setFrame(collapsedFrame, display: true)
        updateStripFrame()
        orderFrontRegardless()
        stripPanel?.orderFrontRegardless()
    }

    /// Reposition to match updated screen coordinates without recreating the window.
    func reposition(to screen: NSScreen) {
        let frame = Self.collapsedFrame(for: screen, mode: mode)
        setFrame(frame, display: true)
        updateStripFrame()
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
