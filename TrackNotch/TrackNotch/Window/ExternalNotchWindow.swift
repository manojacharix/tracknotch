import AppKit
import SwiftUI
import Combine

// MARK: - ExternalStripPanel (software-notch / external monitor)

private final class ExternalStripPanel: NSPanel {
    var onNotchClick: (() -> Void)?
    var onHoverEnter: (() -> Void)?
    var onHoverExit:  (() -> Void)?
    private var pendingMouseDown = false

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque             = false
        backgroundColor      = .clear
        hasShadow            = false
        isMovable            = false
        isReleasedWhenClosed = false
        level                = .mainMenu + 3
        ignoresMouseEvents   = false
        collectionBehavior   = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool  { false }
    override var canBecomeMain: Bool { false }
    override func makeKey() {}

    private var bounds: NSRect { contentView?.bounds ?? .zero }

    override func sendEvent(_ event: NSEvent) {
        guard !ignoresMouseEvents else { super.sendEvent(event); return }
        switch event.type {
        case .leftMouseDown:
            pendingMouseDown = bounds.contains(event.locationInWindow)
        case .leftMouseUp:
            if pendingMouseDown && bounds.contains(event.locationInWindow) { onNotchClick?() }
            pendingMouseDown = false
        default: break
        }
        super.sendEvent(event)
    }
}

// MARK: - ExternalNotchWindow

/// Handles external monitors and notchless built-in Macs.
/// Owns: hover monitor (global mouseMoved), collapseObserver, external strip panel.
final class ExternalNotchWindow: NotchWindowBase {

    private var stripPanel: ExternalStripPanel?
    private var externalHoverMonitor: Any?
    private var collapseObserver: Any?
    private var hoverLeaveTimer: Timer?

    override init(screen: NSScreen, mode: NotchMode) {
        super.init(screen: screen, mode: mode)
        let view = AnyView(
            ExternalMonitorView()
                .environmentObject(ProviderRegistry.shared)
                .environmentObject(AppSettings.shared)
                .environmentObject(frameReporter)
                .font(.system(.body, design: .rounded))
        )
        installContent(view)
        installExternalStripPanel()
        installExternalHoverMonitor()
    }

    // MARK: - Strip panel

    private func installExternalStripPanel() {
        let strip = ExternalStripPanel(frame: hoverRect)
        strip.onNotchClick = { [weak self] in self?.haptic(); self?.toggleDropdown() }
        strip.onHoverEnter = { [weak self] in self?.updateHoverState(inside: true) }
        strip.onHoverExit  = { [weak self] in self?.updateHoverState(inside: false) }
        strip.orderFrontRegardless()
        stripPanel = strip

        collapseObserver = NotificationCenter.default.addObserver(
            forName: .notchCollapseDropdown, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isDropdownVisible else { return }
            self.closeDropdown(fromNotification: true)
        }
    }

    // MARK: - Hover monitor

    private func installExternalHoverMonitor() {
        externalHoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self, let cg = event.cgEvent else { return }
            let sf = self.targetScreen.frame
            let pt = NSPoint(x: cg.location.x, y: sf.origin.y + sf.height - cg.location.y)
            let inside = self.hoverRect.contains(pt)
            DispatchQueue.main.async { self.updateHoverState(inside: inside) }
        }
    }

    private func updateHoverState(inside: Bool) {
        guard !isDropdownVisible else { return }
        hoverLeaveTimer?.invalidate()
        hoverLeaveTimer = nil
        if inside {
            if !ProviderRegistry.shared.isExternalHovered { haptic() }
            ProviderRegistry.shared.isExternalHovered = true
        } else {
            hoverLeaveTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                ProviderRegistry.shared.isExternalHovered = false
                self?.updateExternalStripFrame()
            }
        }
    }

    private func updateExternalStripFrame() {
        guard let strip = stripPanel else { return }
        let newRect = hoverRect
        if strip.frame != newRect { strip.setFrame(newRect, display: true) }
    }

    // MARK: - Hover rect

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

    // MARK: - NotchWindowBase hooks

    override func onDropdownWillOpen() {
        stripPanel?.ignoresMouseEvents = true
        orderFrontRegardless()
    }

    override func onDropdownDidClose() {
        stripPanel?.ignoresMouseEvents = false
        updateExternalStripFrame()
        if let strip = stripPanel { strip.order(.above, relativeTo: windowNumber) }
    }

    override func onShow() {
        stripPanel?.ignoresMouseEvents = false
        stripPanel?.orderFrontRegardless()
    }

    override func onRefreshAfterWake() {
        if let m = externalHoverMonitor { NSEvent.removeMonitor(m); externalHoverMonitor = nil }
        installExternalHoverMonitor()
        hoverLeaveTimer?.invalidate()
        hoverLeaveTimer = nil
        updateExternalStripFrame()
        stripPanel?.orderFrontRegardless()
    }

    override func onReposition() { updateExternalStripFrame() }

    override func close() {
        stripPanel?.close(); stripPanel = nil
        if let m = externalHoverMonitor { NSEvent.removeMonitor(m); externalHoverMonitor = nil }
        if let o = collapseObserver { NotificationCenter.default.removeObserver(o); collapseObserver = nil }
        hoverLeaveTimer?.invalidate()
        hoverLeaveTimer = nil
        ProviderRegistry.shared.isExternalHovered = false
        super.close()
    }
}
