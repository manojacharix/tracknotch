# NotchWindow Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the monolithic `NotchWindow` class into a shared base + two focused subclasses (`HardwareNotchWindow`, `ExternalNotchWindow`) so bugs in one variant cannot regress the other.

**Architecture:** Extract all shared state and logic (dropdown toggle, outside-click monitor, frame reporter, haptic) into `NotchWindowBase: NSPanel`. `HardwareNotchWindow` owns the `StripPanel` + `notchClickMonitor` path. `ExternalNotchWindow` owns the hover monitor + `collapseObserver` path. `DisplayCoordinator` continues to store them as `NotchWindowBase`. The `NotchMode` enum gains a `.softwareNotch` case (distinct from `.externalMonitor`) so the existing tests compile — both still use `ExternalNotchWindow`.

**Tech Stack:** Swift 5.9, AppKit, SwiftUI (via `NSHostingView`), Combine, XCTest

---

## File Map

| Action | Path | Responsibility |
|--------|------|---------------|
| Modify | `TrackNotch/Core/Display/NotchMode.swift` | Add `.softwareNotch` case, update `isExternal`/`isHardware` |
| Create | `TrackNotch/Window/NotchWindowBase.swift` | Shared panel config, hosting view, dropdown open/close, outside-click monitor, frame reporter |
| Create | `TrackNotch/Window/HardwareNotchWindow.swift` | StripPanel, notchClickMonitor, hardware strip geometry |
| Create | `TrackNotch/Window/ExternalNotchWindow.swift` | Hover monitor, collapseObserver, external strip panel, hoverRect |
| Delete | `TrackNotch/Window/NotchWindow.swift` | Replaced by the three files above |
| Modify | `TrackNotch/Core/Display/DisplayCoordinator.swift` | Use `NotchWindowBase`; factory picks subclass by mode |
| Modify | `TrackNotchTests/NotchModeDetectionTests.swift` | Now compiles (`.softwareNotch`, `.externalMonitor` exist) |

---

## Task 1: Add `softwareNotch` to `NotchMode` and fix tests

**Files:**
- Modify: `TrackNotch/TrackNotch/Core/Display/NotchMode.swift`
- Modify: `TrackNotch/TrackNotchTests/NotchModeDetectionTests.swift`

- [ ] **Step 1: Add the new case**

Replace the enum body in `NotchMode.swift`:

```swift
enum NotchMode {
    case hardwareNotch
    case softwareNotch    // notchless built-in Mac (M1 Air etc.) — renders a drawn notch
    case externalMonitor  // standalone external display — renders a floating pill

    static func detect(for screen: NSScreen) -> NotchMode {
        if let left = screen.auxiliaryTopLeftArea, left.width > 0 { return .hardwareNotch }
        if screen.safeAreaInsets.top > 0 { return .hardwareNotch }
        // Distinguish built-in notchless from external by localized name.
        // Built-in screens always contain "Built-in" in their localizedName.
        if screen.localizedName.contains("Built-in") { return .softwareNotch }
        return .externalMonitor
    }

    var isHardware: Bool { self == .hardwareNotch }
    var isExternal: Bool { self == .softwareNotch || self == .externalMonitor }
}
```

- [ ] **Step 2: Run the existing NotchModeDetectionTests**

```bash
cd /Users/manojachari/tracknotch/TrackNotch
xcodebuild test \
  -scheme TrackNotch \
  -destination 'platform=macOS' \
  -only-testing TrackNotchTests/NotchModeDetectionTests \
  2>&1 | grep -E "Test Case|error:|PASSED|FAILED|BUILD"
```

Expected: All 2 existing tests PASS. (The TODO tests still compile but are not yet implemented.)

- [ ] **Step 3: Commit**

```bash
git add TrackNotch/TrackNotch/Core/Display/NotchMode.swift
git commit -m "feat: add NotchMode.softwareNotch distinct from .externalMonitor"
```

---

## Task 2: Create `NotchWindowBase`

This file owns everything shared between the two variants: panel configuration, the `PassthroughHostingView` subclass, `FrameReporter` wiring, dropdown open/close state machine, and the outside-click monitor.

**Files:**
- Create: `TrackNotch/TrackNotch/Window/NotchWindowBase.swift`

- [ ] **Step 1: Create the file**

```swift
import AppKit
import SwiftUI
import Combine

// MARK: - PassthroughHostingView (shared)

final class PassthroughHostingView: NSHostingView<AnyView> {
    var interactiveRectProvider: (() -> NSRect?)?
    var onPillBarTap: (() -> Void)?
    var pillBarHeight: CGFloat = 39

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let rect = interactiveRectProvider?() else { return nil }
        guard rect.contains(point) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if pt.y <= pillBarHeight {
            onPillBarTap?()
            return
        }
        super.mouseDown(with: event)
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

    // MARK: - Constants (subclasses may shadow)
    let expandedWindowWidth:  CGFloat = 420
    let expandedWindowHeight: CGFloat = 280

    let targetScreen: NSScreen
    let mode: NotchMode

    private(set) var isDropdownVisible = false

    /// Publishes the measured dropdown content height from SwiftUI.
    let frameReporter = DropdownFrameReporter()
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
        let hostingView = PassthroughHostingView(rootView: view)
        hostingView.interactiveRectProvider = { [weak self] in self?.interactiveContentRectInView }
        hostingView.onPillBarTap = { [weak self] in
            guard let self, self.isDropdownVisible else { return }
            self.toggleDropdown()
        }
        hostingView.pillBarHeight = notchGeometry(screen: targetScreen).notchHeight
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
        mode.isExternal ? externalPanelFrame(screen: screen) : notchPanelFrame(screen: screen)
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
        let extPillHeight: CGFloat = 32
        let sideInset: CGFloat = 4
        let dropdownW: CGFloat = mode.isExternal
            ? min(380, targetScreen.frame.width - 40)
            : expandedWindowWidth
        let pillW: CGFloat = dropdownW - sideInset * 2
        let measured = frameReporter.dropdownContentHeight
        let contentH: CGFloat = measured > 0 ? measured : 200
        let totalH = extPillHeight + contentH
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

    // MARK: - Open / close (subclasses may override to add variant-specific steps)

    func openDropdown() {
        collapseFinalizeWork?.cancel()
        collapseFinalizeWork = nil
        isDropdownVisible = true
        ignoresMouseEvents = false
        onDropdownWillOpen()         // subclass hook

        NotificationCenter.default.post(name: .notchExpandDropdown, object: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            guard let self, self.isDropdownVisible else { return }
            let pillH: CGFloat = self.mode.isExternal
                ? 32
                : notchGeometry(screen: self.targetScreen).notchHeight
            let dropW: CGFloat = self.mode.isExternal
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
        onDropdownDidClose()         // subclass hook
        if isKeyWindow { resignKey() }
    }

    // MARK: - Subclass hooks (override — don't call super)

    /// Called at the start of openDropdown(), before the notification is posted.
    /// Subclass: reorder panels, disable strip, etc.
    func onDropdownWillOpen() {}

    /// Called at the end of closeDropdown(), after IME is reset.
    /// Subclass: re-enable strip, reorder panels, etc.
    func onDropdownDidClose() {}

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
                let pillH: CGFloat = self.mode.isExternal
                    ? 32
                    : notchGeometry(screen: self.targetScreen).notchHeight
                let dropW: CGFloat = self.mode.isExternal
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

    // MARK: - Public API (called by DisplayCoordinator)

    func show() {
        isDropdownVisible = false
        ignoresMouseEvents = true
        setFrame(collapsedFrame, display: true)
        onShow()          // subclass hook
        orderFrontRegardless()
    }

    /// Called inside show() after frame is set. Subclass: reorder strip panels.
    func onShow() {}

    func forceCollapseDropdownIfOpen() {
        guard isDropdownVisible else { return }
        closeDropdown()
    }

    func refreshAfterWake() {
        onRefreshAfterWake()
        ProviderRegistry.shared.isExternalHovered = false
    }

    /// Subclass: reinstall hover monitors, reset tracking areas.
    func onRefreshAfterWake() {}

    func reposition(to screen: NSScreen) {
        setFrame(Self.collapsedFrame(for: screen, mode: mode), display: true)
        onReposition()
    }

    /// Subclass: update strip panel frame.
    func onReposition() {}

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
}
```

- [ ] **Step 2: Build only (no tests yet — subclasses don't exist)**

```bash
cd /Users/manojachari/tracknotch/TrackNotch
xcodebuild build \
  -scheme TrackNotch \
  -destination 'platform=macOS' \
  2>&1 | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED"
```

Expected: BUILD will FAIL because `NotchWindow.swift` still references `PassthroughHostingView` (duplicate). That's expected — we delete it in Task 5.

- [ ] **Step 3: Commit**

```bash
git add TrackNotch/TrackNotch/Window/NotchWindowBase.swift
git commit -m "feat: add NotchWindowBase — shared panel, dropdown, outside-click monitor"
```

---

## Task 3: Create `HardwareNotchWindow`

Owns everything unique to hardware-notched MacBooks: `StripPanel`, `StripView`, `notchClickMonitor`, hardware strip geometry.

**Files:**
- Create: `TrackNotch/TrackNotch/Window/HardwareNotchWindow.swift`

- [ ] **Step 1: Create the file**

```swift
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
    override func makeKey() { /* no-op */ }

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

/// Handles hardware-notched MacBooks. Owns: StripPanel, notchClickMonitor,
/// hardware wing geometry.
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
            self?.haptic()
            ProviderRegistry.shared.stripEnterCount += 1
            ProviderRegistry.shared.isExternalHovered = true
            self?.updateStripFrame()
        }
        strip.onHoverExit = { [weak self] in
            ProviderRegistry.shared.isExternalHovered = false
            self?.updateStripFrame()
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
        guard ProviderRegistry.shared.isExternalHovered else { return geo.notchWidth }
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
```

- [ ] **Step 2: Build to check for errors**

```bash
cd /Users/manojachari/tracknotch/TrackNotch
xcodebuild build \
  -scheme TrackNotch \
  -destination 'platform=macOS' \
  2>&1 | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED"
```

Expected: Still fails due to `NotchWindow.swift` duplicate symbols. That's fine — Task 5 deletes it.

- [ ] **Step 3: Commit**

```bash
git add TrackNotch/TrackNotch/Window/HardwareNotchWindow.swift
git commit -m "feat: HardwareNotchWindow — strip panel, notchClickMonitor, wing geometry"
```

---

## Task 4: Create `ExternalNotchWindow`

Owns everything unique to external monitors and notchless built-ins: hover monitor, `collapseObserver`, external strip panel, `hoverRect`.

**Files:**
- Create: `TrackNotch/TrackNotch/Window/ExternalNotchWindow.swift`

- [ ] **Step 1: Create the file**

```swift
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
```

- [ ] **Step 2: Commit**

```bash
git add TrackNotch/TrackNotch/Window/ExternalNotchWindow.swift
git commit -m "feat: ExternalNotchWindow — hover monitor, external strip, hoverRect"
```

---

## Task 5: Delete `NotchWindow.swift` and update `DisplayCoordinator`

Now that both subclasses exist, we remove the old monolith and wire `DisplayCoordinator` to use the factory.

**Files:**
- Delete: `TrackNotch/TrackNotch/Window/NotchWindow.swift`
- Modify: `TrackNotch/TrackNotch/Core/Display/DisplayCoordinator.swift`

- [ ] **Step 1: Update `DisplayCoordinator` to use `NotchWindowBase` + factory**

Replace `private var notchWindows: [UInt32: NotchWindow] = [:]` with `NotchWindowBase`, and replace `addWindow` factory:

```swift
// In DisplayCoordinator.swift

// Change property type:
private var notchWindows: [UInt32: NotchWindowBase] = [:]

// Replace addWindow:
private func addWindow(id: UInt32, for screen: NSScreen) {
    let mode = NotchMode.detect(for: screen)
    let window: NotchWindowBase = mode.isHardware
        ? HardwareNotchWindow(screen: screen, mode: mode)
        : ExternalNotchWindow(screen: screen, mode: mode)
    window.show()
    notchWindows[id] = window
}
```

- [ ] **Step 2: Delete `NotchWindow.swift`**

```bash
git rm TrackNotch/TrackNotch/Window/NotchWindow.swift
```

- [ ] **Step 3: Build — must succeed now**

```bash
cd /Users/manojachari/tracknotch/TrackNotch
xcodebuild build \
  -scheme TrackNotch \
  -destination 'platform=macOS' \
  2>&1 | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED"
```

Expected: BUILD SUCCEEDED. Zero errors.

- [ ] **Step 4: Run all tests**

```bash
xcodebuild test \
  -scheme TrackNotch \
  -destination 'platform=macOS' \
  2>&1 | grep -E "Test Case|error:|PASSED|FAILED|BUILD"
```

Expected: All existing tests pass.

- [ ] **Step 5: Commit**

```bash
git add TrackNotch/TrackNotch/Core/Display/DisplayCoordinator.swift
git commit -m "refactor: replace NotchWindow monolith with HardwareNotchWindow + ExternalNotchWindow"
```

---

## Task 6: Add Xcode project references

New Swift files must be added to the Xcode project's `.pbxproj` — otherwise they compile via `xcodebuild` (which picks up all `.swift` files in the directory) but show as missing in Xcode's file navigator.

**Files:**
- Modify: `TrackNotch/TrackNotch.xcodeproj/project.pbxproj`

- [ ] **Step 1: Open Xcode and add files to project**

In Xcode:
1. In the Project Navigator, right-click the `Window/` group
2. Choose "Add Files to TrackNotch…"
3. Select `NotchWindowBase.swift`, `HardwareNotchWindow.swift`, `ExternalNotchWindow.swift`
4. Ensure "Add to target: TrackNotch" is checked
5. Click Add

The deleted `NotchWindow.swift` will show as a missing reference (red) — right-click it and choose "Delete" → "Remove Reference".

- [ ] **Step 2: Build from Xcode (⌘B)**

Expected: Build succeeds, no missing-file warnings.

- [ ] **Step 3: Commit the updated pbxproj**

```bash
git add TrackNotch/TrackNotch.xcodeproj/project.pbxproj
git commit -m "chore: update Xcode project — add split window files, remove NotchWindow.swift"
```

---

## Task 7: Smoke-test both variants manually

**No code changes in this task — testing only.**

- [ ] **Step 1: Test hardware notch variant**

On a notched MacBook:
1. Build and run (`⌘R`)
2. Hover over the notch wings — icons should appear
3. Click the notch — dropdown should open
4. Click outside the dropdown — it should close
5. Click the notch bar while dropdown is open — it should close
6. Open Settings, confirm dropdown closes automatically

- [ ] **Step 2: Test external / software-notch variant**

On an external monitor or notchless Mac:
1. Hover over the pill — it should expand
2. Click — dropdown opens
3. Click outside — closes
4. Lid-close/open cycle — pill reappears correctly

- [ ] **Step 3: Confirm no cross-variant regression**

Connect an external monitor alongside a notched MacBook:
1. Both variants should render simultaneously
2. Clicking the notch on the MacBook should not affect the external pill
3. Clicking the pill on the external should not affect the MacBook notch

---

## Self-Review

**Spec coverage:**
- ✅ `NotchMode.softwareNotch` added — tests now compile
- ✅ `NotchWindowBase` owns all shared logic (dropdown, outside-click, frame reporter)
- ✅ `HardwareNotchWindow` owns strip panel + notchClickMonitor
- ✅ `ExternalNotchWindow` owns hover monitor + collapseObserver
- ✅ `DisplayCoordinator` uses `NotchWindowBase` type, factory picks subclass
- ✅ Old `NotchWindow.swift` deleted
- ✅ Xcode project references updated

**Placeholder scan:** None found.

**Type consistency:**
- `onDropdownWillOpen()` / `onDropdownDidClose()` / `onShow()` / `onRefreshAfterWake()` / `onReposition()` — all defined in base, overridden in both subclasses consistently.
- `frameReporter` — `let` on base, accessed in subclasses via `self.frameReporter` ✅
- `PassthroughHostingView` — moved to base file, no longer private ✅
- `NotchWindowBase` stored as the dict value type in `DisplayCoordinator` ✅
