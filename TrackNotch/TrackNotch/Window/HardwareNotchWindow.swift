import AppKit
import SwiftUI
import Combine

// MARK: - StripPanel + StripView (hardware-notch only)

private final class StripView: NSView {
    var onNotchClick: (() -> Void)?
    var onHoverEnter: (() -> Void)?
    var onHoverExit:  (() -> Void)?
    var clickableRect: NSRect?

    private var installedTrackingRect: NSRect = .null
    private var lastEnterTimestamp: TimeInterval = 0
    private var lastExitTimestamp:  TimeInterval = 0

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateTrackingArea() }
    override func updateTrackingAreas() { super.updateTrackingAreas(); updateTrackingArea() }

    private func updateTrackingArea() {
        if installedTrackingRect == bounds, !trackingAreas.isEmpty { return }
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
        installedTrackingRect = bounds
    }

    override func mouseEntered(with event: NSEvent) {
        let now = event.timestamp
        if now - lastEnterTimestamp < 0.05 { return }
        lastEnterTimestamp = now
        onHoverEnter?()
    }

    override func mouseExited(with event: NSEvent) {
        let now = event.timestamp
        if now - lastExitTimestamp < 0.25 { return }
        lastExitTimestamp = now
        onHoverExit?()
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override var acceptsFirstResponder: Bool        { true }
    override var mouseDownCanMoveWindow: Bool       { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if let r = clickableRect { return r.contains(point) ? self : nil }
        return self
    }
}

private final class StripPanel: NSPanel {
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
        let sv = StripView()
        sv.onNotchClick = { [weak self] in self?.onNotchClick?() }
        sv.onHoverEnter = { [weak self] in self?.onHoverEnter?() }
        sv.onHoverExit  = { [weak self] in self?.onHoverExit?() }
        contentView = sv
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

// MARK: - HardwareNotchWindow

/// Handles hardware-notched MacBooks.
/// Owns: StripPanel, StripView, notchClickMonitor, hardware wing geometry.
final class HardwareNotchWindow: NotchWindowBase {

    private var stripPanel: StripPanel?
    private var notchClickMonitor: Any?

    override init(screen: NSScreen, mode: NotchMode) {
        super.init(screen: screen, mode: mode)
        let view = AnyView(
            NotchRootView(mode: mode, onToggleDropdown: { [weak self] in self?.toggleDropdown() })
                .environmentObject(ProviderRegistry.shared)
                .environmentObject(AppSettings.shared)
                .environmentObject(frameReporter)
                .font(.system(.body, design: .rounded))
        )
        installContent(view)
        installStripPanel()
    }

    // MARK: - Strip panel

    private func installStripPanel() {
        let strip = StripPanel(frame: activeStripRect)
        strip.onNotchClick = { [weak self] in
            self?.haptic()
            self?.toggleDropdown()
        }
        strip.onHoverEnter = { [weak self] in
            guard let self else { return }
            self.haptic()
            self.hoverState.stripEnterCount += 1
            self.hoverState.isHovered = true
            self.updateStripFrame()
        }
        strip.onHoverExit = { [weak self] in
            guard let self else { return }
            self.hoverState.isHovered = false
            self.updateStripFrame()
        }
        strip.orderFrontRegardless()
        stripPanel = strip

        notchClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, !self.isDropdownVisible else { return }
            guard let cg = event.cgEvent else { return }
            let sf = self.targetScreen.frame
            let pt = NSPoint(x: cg.location.x, y: sf.origin.y + sf.height - cg.location.y)
            if self.activeStripRect.contains(pt) {
                DispatchQueue.main.async { self.haptic(); self.toggleDropdown() }
            }
        }
    }

    // MARK: - Strip geometry

    private var stripRect: NSRect {
        let sf = targetScreen.frame
        let stripHeight = getNotchBlockSize(screen: targetScreen).height + 4
        return NSRect(
            x: frame.origin.x,
            y: sf.origin.y + sf.height - stripHeight,
            width: frame.width,
            height: stripHeight
        )
    }

    private var activeStripRect: NSRect { hardwareStripRect }

    private var hardwareStripRect: NSRect {
        let geo = notchGeometry(screen: targetScreen)
        let base = stripRect
        let visible = ProviderRegistry.shared.connectedProviders
            .filter { ProviderRegistry.shared.usageMap[$0] != nil }
        let leftCount  = visible.filter { $0.notchWing == .left }.count
        let rightCount = visible.filter { $0.notchWing == .right }.count
        let leftW  = isDropdownVisible ? 0 : renderedWingWidth(count: leftCount)
        let rightW = isDropdownVisible ? 0 : renderedWingWidth(count: rightCount)
        let contentW = isDropdownVisible ? expandedWindowWidth : max(geo.notchWidth, leftW + geo.notchWidth + rightW)
        let hitPad: CGFloat = isDropdownVisible ? 0 : 6
        let x: CGFloat = isDropdownVisible
            ? frame.midX - contentW / 2
            : frame.origin.x + geo.leftWingWidth - leftW
        return NSRect(x: x - hitPad, y: base.origin.y,
                      width: contentW + hitPad * 2, height: base.height)
    }

    private func renderedWingWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let iconSize: CGFloat = 22
        let iconGap:  CGFloat = 8
        return CGFloat(count) * iconSize + CGFloat(count - 1) * iconGap + 12 + 10
    }

    private var visibleContentWidth: CGFloat {
        let geo = notchGeometry(screen: targetScreen)
        guard hoverState.isHovered else { return geo.notchWidth }
        let visible = ProviderRegistry.shared.connectedProviders
            .filter { ProviderRegistry.shared.usageMap[$0] != nil }
        let leftW  = renderedWingWidth(count: visible.filter { $0.notchWing == .left }.count)
        let rightW = renderedWingWidth(count: visible.filter { $0.notchWing == .right }.count)
        return max(geo.notchWidth, leftW + geo.notchWidth + rightW)
    }

    private func updateStripFrame() {
        guard let strip = stripPanel else { return }
        let newRect = activeStripRect
        if strip.frame != newRect { strip.setFrame(newRect, display: true) }
        guard let sv = strip.contentView as? StripView else { return }
        let visibleW = visibleContentWidth
        let leftMargin = max(0, (newRect.width - visibleW) / 2)
        sv.clickableRect = NSRect(x: leftMargin, y: 0, width: visibleW, height: newRect.height)
    }

    // MARK: - NotchWindowBase hooks

    override func onDropdownWillOpen() {
        stripPanel?.ignoresMouseEvents = true
        updateStripFrame()
        makeKeyAndOrderFront(nil)
    }

    override func onDropdownDidClose() {
        hoverState.isHovered = false
        stripPanel?.ignoresMouseEvents = false
        updateStripFrame()
        if let strip = stripPanel { strip.order(.above, relativeTo: windowNumber) }
    }

    override func onShow() {
        stripPanel?.ignoresMouseEvents = false
        updateStripFrame()
        stripPanel?.orderFrontRegardless()
    }

    override func onRefreshAfterWake() {
        (stripPanel?.contentView as? StripView)?.updateTrackingAreas()
        updateStripFrame()
        stripPanel?.orderFrontRegardless()
    }

    override func onReposition() { updateStripFrame() }

    override func resignKey() {
        super.resignKey()
        if isDropdownVisible { closeDropdown() }
    }

    override func close() {
        stripPanel?.close(); stripPanel = nil
        if let m = notchClickMonitor { NSEvent.removeMonitor(m); notchClickMonitor = nil }
        super.close()
    }
}
