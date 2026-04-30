import AppKit
import SwiftUI

// MARK: - Strip click panel

private final class PassthroughHostingView: NSHostingView<AnyView> {
    var interactiveRectProvider: (() -> NSRect?)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The interactive rect is now live-measured from SwiftUI (see
        // DropdownFrameReporter), so it precisely tracks the visible black
        // shape. Anything outside that rect passes through to apps behind.
        guard let rect = interactiveRectProvider?() else {
            #if DEBUG
            print("[Passthrough] hitTest pt=\(point) rect=nil → pass through")
            #endif
            return nil
        }
        let inside = rect.contains(point)
        #if DEBUG
        print("[Passthrough] hitTest pt=\(point) rect=\(rect) inside=\(inside)")
        #endif
        guard inside else { return nil }
        return super.hitTest(point)
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

    /// Silence the spammy `makeKeyWindow returned NO` warning AppKit prints
    /// every time the cursor enters this panel. We never want to be key.
    override func makeKey() { /* no-op */ }

    #if DEBUG
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .leftMouseUp {
            print("[StripPanel] sendEvent type=\(event.type.rawValue) at \(event.locationInWindow)")
        }
        super.sendEvent(event)
    }
    #endif
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
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        #if DEBUG
        print("[StripView] mouseEntered")
        #endif
        onHoverEnter?()
    }
    override func mouseExited(with event: NSEvent) {
        #if DEBUG
        print("[StripView] mouseExited")
        #endif
        onHoverExit?()
    }
    override func mouseDown(with event: NSEvent) {
        #if DEBUG
        print("[StripView] mouseDown at \(event.locationInWindow)")
        #endif
    }
    override func mouseUp(with event: NSEvent) {
        #if DEBUG
        print("[StripView] mouseUp at \(event.locationInWindow)")
        #endif
        onNotchClick?()
    }
    override var acceptsFirstResponder: Bool        { true }
    override var mouseDownCanMoveWindow: Bool       { false }

    /// Required because StripPanel is a non-key `nonactivatingPanel`. Without
    /// this AppKit silently drops mouseDown/mouseUp before they reach this
    /// view's overrides — the click events arrive at the panel's `sendEvent`
    /// but never get routed through.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
    private var collapseObserver: Any?

    /// Publishes the measured dropdown content height from SwiftUI.
    /// Consumed by `interactiveContentRectInView` to compute a tight hit-test rect.
    private let frameReporter = DropdownFrameReporter()

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
                    .environmentObject(frameReporter)
            )
            hostingView = PassthroughHostingView(rootView: view)
        } else {
            let view = AnyView(
                NotchRootView(mode: mode, onToggleDropdown: { [weak self] in
                    self?.toggleDropdown()
                })
                .environmentObject(ProviderRegistry.shared)
                .environmentObject(AppSettings.shared)
                .environmentObject(frameReporter)
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
            // Use targetScreen geometry for correct coordinate translation.
            // CGEvent origin is top-left of primary screen; AppKit origin is bottom-left.
            let sf = self.targetScreen.frame
            let appKitPt = NSPoint(x: cg.location.x, y: sf.origin.y + sf.height - cg.location.y)
            let inside = self.hoverRect.contains(appKitPt)
            DispatchQueue.main.async {
                self.updateHoverState(inside: inside)
            }
        }
    }

    private func updateHoverState(inside: Bool) {
        hoverLeaveTimer?.invalidate()
        hoverLeaveTimer = nil
        if inside {
            if !ProviderRegistry.shared.isExternalHovered { haptic() }
            ProviderRegistry.shared.isExternalHovered = true
            // Do NOT resize here — resizing while the cursor is entering triggers a second
            // mouseEntered from the tracking area (resize feedback loop).
        } else {
            hoverLeaveTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                ProviderRegistry.shared.isExternalHovered = false
                // Safe to resize on exit — cursor is already leaving
                self?.updateExternalStripFrame()
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
        let bounds = contentView.bounds

        // Tight, dropdown-aware rect. Trimmed by 4pt per side to release the
        // shadow / anti-alias margin so adjacent clicks pass through cleanly.
        // Trade-off: the bottom-corner curved areas (NotchShape uses a 26pt
        // bottom corner radius) are a flat rectangle here, so a small triangle
        // in each bottom corner over-claims clicks. Acceptable — the visible
        // shape is clearly pill-like to the user.
        let extPillHeight: CGFloat = 32
        let sideInset: CGFloat = 4
        let menuBarH = targetScreen.frame.height - (targetScreen.visibleFrame.maxY - targetScreen.frame.origin.y)
        let pillW: CGFloat = expandedWindowWidth - sideInset * 2

        // GeometryReader fires once the dropdown SwiftUI view appears (~0.05s
        // after openDropdown). Use a tight floor (≈ default expandedContentHeight)
        // for that brief window so first clicks aren't dropped.
        let measured = frameReporter.dropdownContentHeight
        let contentH: CGFloat = measured > 0 ? measured : 200

        // dropdownContentHeight already includes DropdownContent's own
        // .padding(.top, 8) + .padding(.bottom, 8), so no extra safety needed.
        let totalH = extPillHeight + contentH
        let topEdgeY = menuBarH

        return NSRect(
            x: bounds.midX - pillW / 2,
            y: bounds.height - topEdgeY - totalH,
            width: pillW,
            height: totalH
        )
    }

    // MARK: - Hover rect (external mode)

    /// Click/hover zone for external monitor: sized to the fully-expanded pill state.
    /// Using connected count (not active count) keeps the panel stable — it never
    /// resizes when hover state changes, which would trigger a second mouseEntered
    /// from the tracking area (resize feedback loop).
    private var hoverRect: NSRect {
        let registry  = ProviderRegistry.shared
        let iconCount = registry.connectedProviders.filter { registry.usageMap[$0] != nil }.count
        let sf        = targetScreen.frame
        return PillGeometry().hoverRect(
            in: sf,
            visibleFrameMaxY: targetScreen.visibleFrame.maxY,
            windowMidX: frame.midX,
            iconCount: iconCount
        )
    }

    // MARK: - Haptic

    private func haptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    // MARK: - Dropdown (now expands in-place inside NotchWindow)

    func toggleDropdown() {
        #if DEBUG
        print("[NotchWindow] toggleDropdown: isDropdownVisible=\(isDropdownVisible)")
        #endif
        isDropdownVisible ? closeDropdown() : openDropdown()
    }

    private func openDropdown() {
        #if DEBUG
        print("[NotchWindow] openDropdown called, frame=\(frame)")
        #endif
        collapseFinalizeWork?.cancel()
        collapseFinalizeWork = nil
        isDropdownVisible = true

        // Allow hit-testing and make key so SwiftUI buttons fire correctly
        ignoresMouseEvents = false
        stripPanel?.ignoresMouseEvents = true
        updateStripFrame()
        makeKeyAndOrderFront(nil)

        // Tell SwiftUI view to expand
        NotificationCenter.default.post(name: .notchExpandDropdown, object: nil)

        // Cancel any lingering outside-click monitor before installing a new one
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }

        // Install outside-click monitor after a short delay to avoid catching the
        // triggering mouseDown or any buffered prior clicks in the event queue.
        let installTime = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.isDropdownVisible else { return }
            self.outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self else { return }
                guard event.timestamp > installTime.timeIntervalSinceReferenceDate else { return }
                guard let cg = event.cgEvent else { return }
                // Use targetScreen for correct coordinate translation
                let sf = self.targetScreen.frame
                let appKitPt = NSPoint(x: cg.location.x, y: sf.origin.y + sf.height - cg.location.y)
                if !self.frame.contains(appKitPt) {
                    DispatchQueue.main.async { self.closeDropdown() }
                }
            }
        }
    }

    private func closeDropdown(fromNotification: Bool = false) {
        #if DEBUG
        print("[NotchWindow] closeDropdown called (fromNotification=\(fromNotification))")
        #endif
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
        }
        // Resign key AFTER reordering to prevent macOS from shuffling windows
        if isKeyWindow { resignKey() }
    }

    // MARK: - Public

    func show() {
        setFrame(collapsedFrame, display: true)
        updateStripFrame()
        orderFrontRegardless()
        stripPanel?.orderFrontRegardless()
    }

    /// Refresh event monitors and tracking areas after sleep/wake.
    /// The global mouseMoved monitor context goes stale during sleep.
    func refreshAfterWake() {
        if let m = externalHoverMonitor { NSEvent.removeMonitor(m); externalHoverMonitor = nil }
        if mode.isExternal { installExternalHoverMonitor() }
        // Reset any stale hover state from before sleep
        ProviderRegistry.shared.isExternalHovered = false
        hoverLeaveTimer?.invalidate()
        hoverLeaveTimer = nil
        // Refresh AppKit tracking areas
        (stripPanel?.contentView as? StripView)?.updateTrackingAreas()
        updateStripFrame()
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
