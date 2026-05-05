import AppKit
import SwiftUI
import Combine

// MARK: - Strip click panel

private final class PassthroughHostingView: NSHostingView<AnyView> {
    var interactiveRectProvider: (() -> NSRect?)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let rect = interactiveRectProvider?() else { return nil }
        guard rect.contains(point) else { return nil }
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

    /// Tracks whether a left-mouse-down landed inside the content view, so
    /// the matching mouse-up can fire `onNotchClick` even when the responder
    /// chain to `StripView` is interrupted (which happens when the panel
    /// sits on the menu bar zone — macOS doesn't always route clicks through
    /// to subviews of nonactivating panels at level `.mainMenu + N`).
    private var pendingMouseDown: Bool = false

    override func sendEvent(_ event: NSEvent) {
        // While the dropdown is open, the panel is set to ignoresMouseEvents
        // and clicks should fall through. Don't fire onNotchClick in that
        // state — otherwise we toggle the dropdown closed-then-open in one
        // user click and it appears stuck.
        guard !ignoresMouseEvents else {
            super.sendEvent(event)
            return
        }
        switch event.type {
        case .leftMouseDown:
            let inside = bounds.contains(event.locationInWindow)
            NSLog("[TN.diag] StripPanel down at=\(event.locationInWindow) bounds=\(bounds) inside=\(inside)")
            pendingMouseDown = inside
        case .leftMouseUp:
            let inside = bounds.contains(event.locationInWindow)
            NSLog("[TN.diag] StripPanel up at=\(event.locationInWindow) inside=\(inside) pending=\(pendingMouseDown)")
            if pendingMouseDown && inside {
                onNotchClick?()
            }
            pendingMouseDown = false
        default:
            break
        }
        super.sendEvent(event)
    }

    private var bounds: NSRect { contentView?.bounds ?? .zero }
}

private final class StripView: NSView {
    var onNotchClick: (() -> Void)?
    var onHoverEnter: (() -> Void)?
    var onHoverExit:  (() -> Void)?
    /// Rect within bounds that accepts clicks. nil = full bounds.
    var clickableRect: NSRect?

    /// Last bounds we installed a tracking area for. Used to skip rebuild when
    /// AppKit fires updateTrackingAreas() but bounds haven't actually changed —
    /// each rebuild creates a new .activeAlways area which immediately fires
    /// mouseEntered if the cursor is inside, causing a hover-thrash loop.
    private var installedTrackingRect: NSRect = .null

    /// Timestamp-based debounce for AppKit's burst-firing enter/exit during
    /// tracking-area rebuilds. Enter coalesce window is short (50ms) so real
    /// entries feel responsive; exit window is longer (250ms) because the
    /// dominant noise source is boundary wobble at the wing edge during
    /// animation. The cursor-truth check on the consumer side
    /// (NotchRootView's hoverSettleWork) is the authoritative guard for
    /// "AppKit lied about cursor leaving" — producer-side debounce is
    /// intentionally minimal.
    private var lastEnterTimestamp: TimeInterval = 0
    private var lastExitTimestamp:  TimeInterval = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingArea()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingArea()
    }

    private func updateTrackingArea() {
        if installedTrackingRect == bounds, !trackingAreas.isEmpty { return }
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
        installedTrackingRect = bounds
    }

    override func mouseEntered(with event: NSEvent) {
        let now = event.timestamp
        if now - lastEnterTimestamp < 0.05 { return }
        lastEnterTimestamp = now
        NSLog("[TN.diag] StripView mouseEntered")
        onHoverEnter?()
    }

    override func mouseExited(with event: NSEvent) {
        let now = event.timestamp
        if now - lastExitTimestamp < 0.25 { return }
        lastExitTimestamp = now
        NSLog("[TN.diag] StripView mouseExited")
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
        // Click → toggle is dispatched by StripPanel.sendEvent (single source
        // of truth). Don't fire it here too — that caused every click to
        // toggle the dropdown twice (open then immediately close).
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
    private let expandedWindowWidth: CGFloat = 420
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
    private var notchClickMonitor: Any?
    private var collapseFinalizeWork: DispatchWorkItem?
    private var collapseObserver: Any?
    /// Reentry guard for toggleDropdown — both StripPanel.sendEvent and the
    /// global notchClickMonitor can fire for the same physical click.
    private var lastToggleTime: TimeInterval = 0

    /// Publishes the measured dropdown content height from SwiftUI.
    /// Consumed by `interactiveContentRectInView` to compute a tight hit-test rect.
    private let frameReporter = DropdownFrameReporter()
    private var contentHeightCancellable: AnyCancellable?

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
                    .font(.system(.body, design: .rounded))
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
                .font(.system(.body, design: .rounded))
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
            NSLog("[TN.diag] strip.onNotchClick fired isDropdownVisible=\(self?.isDropdownVisible ?? false)")
            self?.haptic()
            self?.toggleDropdown()
        }
        strip.onHoverEnter = { [weak self] in
            self?.haptic()
            // Increment the count BEFORE flipping isExternalHovered so the
            // shouldShow→true callback in NotchRootView observes the new
            // count and the hover-after-close gate clears in the same turn.
            ProviderRegistry.shared.stripEnterCount += 1
            NSLog("[TN.diag] stripEnterCount=\(ProviderRegistry.shared.stripEnterCount)")
            ProviderRegistry.shared.isExternalHovered = true
            // Refresh ONLY the clickableRect (hardwareStripRect itself is
            // hover-independent so the panel frame won't change — this just
            // expands the click hit zone to cover the now-visible wings).
            self?.updateStripFrame()
        }
        strip.onHoverExit = { [weak self] in
            ProviderRegistry.shared.isExternalHovered = false
            self?.updateStripFrame()
        }
        strip.orderFrontRegardless()
        stripPanel = strip

        // Global click monitor: catches left-mouse-down anywhere on screen
        // and fires the toggle if the click landed inside the active strip
        // rect. Bypasses the .nonactivatingPanel routing problem entirely.
        // Global mouseDown monitor as a click fallback for hardware-notched
        // displays where .nonactivatingPanel.sendEvent routing in the menu-
        // bar zone is unreliable. NOTE: this only catches clicks landing on
        // OTHER apps' windows. Clicks landing on our own NotchWindow /
        // StripPanel rely on the strip panel's own sendEvent path. We do
        // NOT add a local monitor — it interferes with SwiftUI gesture
        // recognition (drag, button taps) inside the dropdown.
        notchClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return }
            guard !self.isDropdownVisible else { return }
            guard let cg = event.cgEvent else { return }
            let sf = self.targetScreen.frame
            let appKitPt = NSPoint(x: cg.location.x, y: sf.origin.y + sf.height - cg.location.y)
            if self.activeStripRect.contains(appKitPt) {
                DispatchQueue.main.async {
                    self.haptic()
                    self.toggleDropdown()
                }
            }
        }
    }

    override func close() {
        stripPanel?.close()
        stripPanel = nil
        if let m = externalClickMonitor { NSEvent.removeMonitor(m); externalClickMonitor = nil }
        if let m = externalHoverMonitor { NSEvent.removeMonitor(m); externalHoverMonitor = nil }
        if let m = outsideClickMonitor  { NSEvent.removeMonitor(m); outsideClickMonitor  = nil }
        if let m = notchClickMonitor    { NSEvent.removeMonitor(m); notchClickMonitor    = nil }
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

        // Size to the FULL expanded wing width regardless of hover state.
        // Resizing the strip on hoverEnter/hoverExit creates a feedback loop:
        // resize → cursor falls outside the new tracking area → exit fires →
        // resize back → cursor is inside again → enter fires → forever.
        // Using connectedProviders (the fully-expanded shape) keeps the strip
        // stable so AppKit's tracking area only fires once per real entry/exit.
        // Bonus: the click hit zone now spans the full wing, not just center.
        let visibleProviders = ProviderRegistry.shared.connectedProviders
            .filter { ProviderRegistry.shared.usageMap[$0] != nil }

        let leftCount = visibleProviders.filter { $0.notchWing == .left }.count
        let rightCount = visibleProviders.filter { $0.notchWing == .right }.count

        let leftWingWidth = isDropdownVisible ? 0 : renderedWingWidth(count: leftCount)
        let rightWingWidth = isDropdownVisible ? 0 : renderedWingWidth(count: rightCount)
        let contentWidth = isDropdownVisible ? expandedWindowWidth : max(geo.notchWidth, leftWingWidth + geo.notchWidth + rightWingWidth)
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
        guard let sv = strip.contentView as? StripView else { return }

        // The panel itself is sized to the full wing extent for stability
        // (resizing on hover triggers tracking-area rebuild loops). But we
        // narrow the actual clickable hit zone to match what's visually drawn,
        // so clicks landing in the empty wing zone fall through to apps below
        // instead of being absorbed by an invisible rectangle.
        if mode.isExternal || isDropdownVisible {
            let pad: CGFloat = isDropdownVisible ? 0 : 6
            sv.clickableRect = pad > 0
                ? NSRect(x: pad, y: 0, width: newRect.width - pad * 2, height: newRect.height)
                : nil
            return
        }

        // Hardware-notched, dropdown closed: clickable rect mirrors the
        // visible content. Always at least the notch zone; expanded to wing
        // extents only when hovered.
        let visibleWidth = visibleContentWidth
        let leftMargin = max(0, (newRect.width - visibleWidth) / 2)
        sv.clickableRect = NSRect(
            x: leftMargin,
            y: 0,
            width: visibleWidth,
            height: newRect.height
        )
    }

    /// Width of the actually-drawn pill content within the strip, in the
    /// strip's local coordinate space. Notch-zone-only when idle; expands
    /// to include wings when hovered.
    private var visibleContentWidth: CGFloat {
        let geo = notchGeometry(screen: targetScreen)
        let hovered = ProviderRegistry.shared.isExternalHovered
        guard hovered else { return geo.notchWidth }
        let visibleProviders = ProviderRegistry.shared.connectedProviders
            .filter { ProviderRegistry.shared.usageMap[$0] != nil }
        let leftCount = visibleProviders.filter { $0.notchWing == .left }.count
        let rightCount = visibleProviders.filter { $0.notchWing == .right }.count
        let leftW = renderedWingWidth(count: leftCount)
        let rightW = renderedWingWidth(count: rightCount)
        return max(geo.notchWidth, leftW + geo.notchWidth + rightW)
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
        let pillW: CGFloat = expandedWindowWidth - sideInset * 2

        // GeometryReader fires once the dropdown SwiftUI view appears (~0.05s
        // after openDropdown). Use a tight floor (≈ default expandedContentHeight)
        // for that brief window so first clicks aren't dropped.
        let measured = frameReporter.dropdownContentHeight
        let contentH: CGFloat = measured > 0 ? measured : 200

        // dropdownContentHeight already includes DropdownContent's own
        // .padding(.top, 8) + .padding(.bottom, 8), so no extra safety needed.
        let totalH = extPillHeight + contentH
        // Pill now sits ON the menu bar (top of window in SwiftUI coords).
        let topEdgeY: CGFloat = 0

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
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastToggleTime < 0.2 {
            NSLog("[TN.diag] toggleDropdown DEBOUNCED (Δ=\(now - lastToggleTime)s)")
            return
        }
        lastToggleTime = now
        NSLog("[TN.diag] toggleDropdown isDropdownVisible=\(isDropdownVisible)")
        isDropdownVisible ? closeDropdown() : openDropdown()
    }

    /// Resize the panel to fit the live-measured dropdown content height.
    /// SwiftUI publishes the rendered content height via `frameReporter`;
    /// this re-tightens the panel so the dead-click zone below the visible
    /// shape stays at zero regardless of how many provider pills render.
    private func observeDropdownContentHeight() {
        contentHeightCancellable?.cancel()
        // Debounce SwiftUI's measurement bursts (the dropdown content
        // animates open across multiple frames; each renders a new
        // height) so we don't visibly resize the panel several times
        // per dropdown open. 80ms debounce settles to a stable size
        // before committing the resize, eliminating the left/right
        // jitter the user observed.
        contentHeightCancellable = frameReporter.$dropdownContentHeight
            .removeDuplicates()
            .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .sink { [weak self] h in
                guard let self, self.isDropdownVisible, h > 0 else { return }
                let pillH = notchGeometry(screen: self.targetScreen).notchHeight
                let totalH = pillH + h
                let collapsed = self.collapsedFrame
                let cx = collapsed.midX
                let newFrame = NSRect(
                    x: cx - self.expandedWindowWidth / 2,
                    y: collapsed.maxY - totalH,
                    width: self.expandedWindowWidth,
                    height: totalH
                )
                if !NSEqualRects(self.frame, newFrame) {
                    // animate:false so the panel snaps to size without
                    // AppKit's default frame animation (which the user
                    // perceives as the dropdown "resizing weirdly").
                    self.setFrame(newFrame, display: true, animate: false)
                }
            }
    }

    private func openDropdown() {
        NSLog("[TN.diag] openDropdown frame=\(frame) ignoresMouseEvents=\(ignoresMouseEvents) stripIME=\(stripPanel?.ignoresMouseEvents ?? true)")
        collapseFinalizeWork?.cancel()
        collapseFinalizeWork = nil
        isDropdownVisible = true

        // Keep the panel at its FULL collapsed size (580×400) during the
        // open animation so SwiftUI's ease-in/out plays inside the
        // panel's full canvas — no apparent shift or finicky resize.
        // The shrink to fit-the-visible-dropdown happens AFTER the
        // SwiftUI open animation settles (see scheduled work below).

        // Allow hit-testing. On external monitors use orderFrontRegardless
        // instead of makeKeyAndOrderFront — the panel is non-activating and
        // makeKeyAndOrderFront causes it to briefly become key then immediately
        // lose key back to the previous app, firing resignKey() → closeDropdown()
        // → notchCollapseDropdown loop on notchless Macs.
        ignoresMouseEvents = false
        stripPanel?.ignoresMouseEvents = true
        updateStripFrame()
        if mode.isExternal {
            orderFrontRegardless()
        } else {
            makeKeyAndOrderFront(nil)
        }
        NSLog("[TN.diag] openDropdown post-makeKey isVisible=\(isVisible) alpha=\(alphaValue) level=\(level.rawValue) frame=\(frame)")

        // Tell SwiftUI view to expand
        NotificationCenter.default.post(name: .notchExpandDropdown, object: nil)
        // After the SwiftUI open animation settles (~0.5s), snap the
        // panel to the fit-the-visible-shape size. The visible NotchShape
        // is centered on the physical notch and stays put through the
        // shrink (we keep X centered on notch, Y pinned to top), so the
        // user sees no movement — only the surrounding transparent dead
        // zone collapses so clicks outside the shape pass through.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            guard let self, self.isDropdownVisible else { return }
            let pillH = notchGeometry(screen: self.targetScreen).notchHeight
            let measured = self.frameReporter.dropdownContentHeight
            let contentH: CGFloat = measured > 0 ? measured : 200
            let totalH = pillH + contentH
            let collapsed = self.collapsedFrame
            let cx = collapsed.midX
            let newFrame = NSRect(
                x: cx - self.expandedWindowWidth / 2,
                y: collapsed.maxY - totalH,
                width: self.expandedWindowWidth,
                height: totalH
            )
            self.setFrame(newFrame, display: true, animate: false)
            // Tell SwiftUI to switch its canvas math to the 420 layout
            // (no horizontal offset) — keeps the visible pill position
            // invariant across the snap.
            self.frameReporter.panelFitsVisibleShape = true
            // Now that SwiftUI is settled, observe content-height
            // changes so subsequent grid additions/removals re-tighten.
            self.observeDropdownContentHeight()
        }

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
                // Close when click is outside the *visible* dropdown shape,
                // not just outside the (much larger) transparent window frame.
                // Convert the visible-content rect from view coords to screen coords.
                guard let interactive = self.interactiveContentRectInView else {
                    if !self.frame.contains(appKitPt) {
                        DispatchQueue.main.async { self.closeDropdown() }
                    }
                    return
                }
                let visibleScreenRect = NSRect(
                    x: self.frame.origin.x + interactive.origin.x,
                    y: self.frame.origin.y + interactive.origin.y,
                    width: interactive.width,
                    height: interactive.height
                )
                if !visibleScreenRect.contains(appKitPt) {
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

        // Stop tracking content-height changes and restore the FULL
        // collapsed frame BEFORE the SwiftUI close animation starts so
        // the ease-in/out plays inside the panel's full canvas. Flip
        // the SwiftUI canvas math FIRST (to 580-wide layout with pill
        // offset 80) so the pill stays at the same screen position when
        // the window grows back.
        contentHeightCancellable?.cancel()
        contentHeightCancellable = nil
        frameReporter.panelFitsVisibleShape = false
        setFrame(collapsedFrame, display: true, animate: false)

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
        // Belt-and-suspenders: always start in the collapsed/click-through
        // state. Guards against any path where the previous instance left
        // ignoresMouseEvents in a wedged state (e.g. a Disable→Enable cycle
        // performed while the dropdown was open).
        isDropdownVisible = false
        ignoresMouseEvents = true
        stripPanel?.ignoresMouseEvents = false
        setFrame(collapsedFrame, display: true)
        updateStripFrame()
        orderFrontRegardless()
        stripPanel?.orderFrontRegardless()
    }

    override func resignKey() {
        super.resignKey()
        // External monitor panels never become key (orderFrontRegardless), so
        // resignKey is spurious — skip to avoid the openDropdown→resignKey→
        // closeDropdown loop on notchless Macs.
        guard !mode.isExternal else { return }
        // If we lost key while the dropdown was visible, another window grabbed
        // focus (e.g. the Settings dialog opened via the menu bar). Force-close
        // the dropdown so our state flags reset and the new key window can
        // actually receive clicks.
        if isDropdownVisible {
            closeDropdown()
        }
    }

    /// External entry point used by DisplayCoordinator.collapseAnyOpenDropdown()
    /// to preemptively close the dropdown before a competing window opens.
    /// Distinct from closeDropdown() because we want callers outside the
    /// SwiftUI/notification flow to be able to trigger collapse without
    /// guessing at the right entry point.
    func forceCollapseDropdownIfOpen() {
        guard isDropdownVisible else { return }
        closeDropdown()
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
