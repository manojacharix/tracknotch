import SwiftUI

// MARK: - External Monitor overlay
//
// Two-layer animation model:
//   Layer 1 — Pill shape: circle → expand both sides → full width (or reverse)
//   Layer 2 — Icons: populate from center outward to positions (or reverse)
//
// States:
//   Idle (no activity)  → invisible (dot imploded to 0)
//   Idle (active)       → pill visible with active provider icons
//   Hover               → pill expands, all connected providers populate from center
//   Click               → dropdown expands below the pill
//
// Hover-in:  dot → circle → pill expands both sides → icons populate from center outward
// Hover-out: icons retract to center → pill contracts to circle → implode to dot → fade out

private let iconSize:         CGFloat = 22
private let iconGap:          CGFloat = 8
private let sidePadding:      CGFloat = 16
private let extPillHeight:    CGFloat = 32
private let pillCornerRadius: CGFloat = 14
private let dotSize:          CGFloat = 8
private let circleSize:       CGFloat = 32   // circle before expanding to pill
private let staggerStep:      Double  = 0.04

// Expanded dropdown dimensions — match notch version, capped for small screens
private let extExpandedMaxWidth:       CGFloat = 380
private let extExpandedTopRadius:      CGFloat = 10
private let extExpandedBottomRadius:   CGFloat = 26

struct ExternalMonitorView: View {
    @EnvironmentObject var registry: ProviderRegistry
    @EnvironmentObject var frameReporter: DropdownFrameReporter

    /// Height of the macOS menu bar on this screen — pill sits just below it.
    private var menuBarHeight: CGFloat {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return 24 }
        return screen.frame.height - screen.visibleFrame.maxY
    }

    /// Dropdown width capped to avoid clipping on small external monitors
    private var extExpandedWidth: CGFloat {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return extExpandedMaxWidth }
        return min(extExpandedMaxWidth, screen.frame.width - 40)
    }

    // MARK: - Layer 1: Pill state

    /// Controls whether pill is in the view tree at all
    @State private var pillInTree: Bool = false
    /// Pill expansion phase: dot(0) → circle(1) → full pill(2)
    @State private var pillPhase: Int = 0
    /// Pill opacity for the final fade-out
    @State private var pillOpacity: Double = 0

    // MARK: - Layer 2: Icon state

    /// When true, icons are visible and spread out from center
    @State private var iconsSpread: Bool = false

    // MARK: - Collapse sequencing
    @State private var collapseWork: DispatchWorkItem? = nil
    @State private var closeWork: DispatchWorkItem? = nil
    @State private var phaseAdvanceWork: DispatchWorkItem? = nil
    @State private var iconSpreadWork: DispatchWorkItem? = nil
    @State private var iconRestoreWork: DispatchWorkItem? = nil

    // MARK: - Dropdown state
    @State private var isExpanded: Bool = false
    @State private var contentVisible: Bool = false
    @State private var isEditMode: Bool = false
    @State private var expandedContentHeight: CGFloat = 200
    @State private var transitionNonce: Int = 0

    private var isHovered: Bool { registry.isExternalHovered }

    // Idle: only active/lingering providers. Hover: all connected with usage data.
    private var visibleProviders: [LLMProvider] {
        if isHovered || isExpanded {
            return registry.connectedProviders.filter { registry.usageMap[$0] != nil }
        }
        return registry.activeProviders
    }

    private var hasIcons: Bool { !visibleProviders.isEmpty }

    // MARK: - Pill sizing

    private var targetPillWidth: CGFloat {
        let count = CGFloat(max(visibleProviders.count, 1))
        return count * iconSize + max(0, count - 1) * iconGap + sidePadding * 2
    }

    /// Current pill width based on phase
    private var pillWidth: CGFloat {
        switch pillPhase {
        case 0:  return dotSize
        case 1:  return circleSize
        default: return isExpanded ? extExpandedWidth : targetPillWidth
        }
    }

    private var pillHeight: CGFloat {
        switch pillPhase {
        case 0:  return dotSize
        case 1:  return circleSize
        default: return extPillHeight
        }
    }

    private var pillRadius: CGFloat {
        switch pillPhase {
        case 0:  return dotSize / 2
        case 1:  return circleSize / 2
        default: return pillCornerRadius
        }
    }

    private var shapeHeight: CGFloat {
        isExpanded ? extPillHeight + expandedContentHeight : pillHeight
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .frame(width: trackNotchWindowWidth, height: trackNotchWindowHeight)
                .allowsHitTesting(false)

            if pillInTree {
                ZStack(alignment: .top) {
                    // Layer 1: The pill shape
                    if isExpanded {
                        NotchShape(
                            topCornerRadius: extExpandedTopRadius,
                            bottomCornerRadius: extExpandedBottomRadius
                        )
                        .fill(Color.black)
                        .frame(width: pillWidth, height: shapeHeight)
                        .shadow(color: .black.opacity(0.7), radius: 24, y: 10)
                    } else if pillPhase >= 2 {
                        // Fully-expanded pill: use NotchShape silhouette so the
                        // notchless pill visually mimics wings (flat top, inward
                        // top corners, outward bottom corners).
                        NotchShape(topCornerRadius: 6, bottomCornerRadius: pillCornerRadius)
                            .fill(Color.black)
                            .frame(width: pillWidth, height: pillHeight)
                            .shadow(color: .black.opacity(0.4), radius: 6, y: 0)
                    } else {
                        // Dot / circle morph phases stay round.
                        RoundedRectangle(cornerRadius: pillRadius)
                            .fill(Color.black)
                            .frame(width: pillWidth, height: pillHeight)
                            .shadow(color: .black.opacity(0.2), radius: 2, y: 0)
                    }

                    // Layer 2: Icons — only when pill is fully expanded (phase 2) and not in dropdown
                    if pillPhase >= 2 && !isExpanded {
                        iconsView
                            .frame(width: targetPillWidth, height: extPillHeight)
                    }

                    // Expanded: edit + settings bar
                    if isExpanded {
                        HStack {
                            Button(isEditMode ? "done" : "edit") {
                                isEditMode.toggle()
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                            .contentShape(Capsule())

                            Spacer()

                            Button("settings") {
                                // Don't post notchCollapseDropdown here.
                                // ConnectionWindow.open() makes the dialog
                                // key; NotchWindow.resignKey() then handles
                                // the dropdown collapse via closeDropdown(),
                                // which posts the notification once. Posting
                                // it twice from here used to leave NotchWindow's
                                // isDropdownVisible flag out of sync with the
                                // SwiftUI isExpanded state, so subsequent pill
                                // clicks were no-ops.
                                ConnectionWindowController.shared.open()
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                            .contentShape(Capsule())
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                        .frame(width: pillWidth, height: extPillHeight)
                        // No parent .onTapGesture here — it raced with the
                        // child Buttons (Edit/Settings) and would sometimes
                        // win the tap, posting collapse and swallowing the
                        // button's action. Outside-the-pill clicks are
                        // already handled by NotchWindow.outsideClickMonitor.
                        .opacity(contentVisible ? 1 : 0)
                    }

                    // Expanded: dropdown content
                    if isExpanded {
                        VStack(spacing: 0) {
                            Color.clear.frame(height: extPillHeight)

                            DropdownContent(onDismiss: {
                                NotificationCenter.default.post(name: .notchCollapseDropdown, object: nil)
                            }, isEditMode: $isEditMode)
                                .padding(.top, 8)
                                .padding(.horizontal, 4)
                                .padding(.bottom, 8)
                                .opacity(contentVisible ? 1 : 0)
                                .background(
                                    GeometryReader { proxy in
                                        Color.clear.onAppear {
                                            expandedContentHeight = proxy.size.height
                                            frameReporter.dropdownContentHeight = proxy.size.height
                                        }.onChange(of: proxy.size.height) { h in
                                            expandedContentHeight = h
                                            frameReporter.dropdownContentHeight = h
                                        }
                                    }
                                )
                        }
                        .frame(width: pillWidth)
                        .clipped()
                    }
                }
                .frame(width: isExpanded ? pillWidth : nil, height: shapeHeight, alignment: .top)
                .opacity(pillOpacity)
                .animation(.easeInOut(duration: 0.25), value: pillWidth)
                .animation(.easeInOut(duration: 0.25), value: pillHeight)
                .animation(.easeInOut(duration: 0.2), value: pillRadius)
                .animation(.easeInOut(duration: 0.2), value: pillOpacity)
                .animation(.smooth(duration: 0.35), value: isExpanded)
                .animation(.smooth(duration: 0.35), value: shapeHeight)
                .allowsHitTesting(isExpanded)
                .frame(maxWidth: .infinity, alignment: .center)
                // Pill sits ON the menu bar (overlapping it). Stays
                // horizontally centred so it doesn't collide with system
                // status icons on the right or app menus on the left.
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .notchExpandDropdown)) { _ in
            openExpanded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .notchCollapseDropdown)) { _ in
            closeExpanded()
        }
        .onChange(of: isHovered) { hovered in
            guard !isExpanded else { return }
            if hovered {
                hoverIn()
            } else {
                hoverOut()
            }
        }
        .onChange(of: hasIcons) { nowHasIcons in
            guard !isExpanded && !isHovered else { return }
            if nowHasIcons {
                cancelCollapse()
                showWithActivity()
            } else {
                activityOut()
            }
        }
        .onAppear {
            if hasIcons {
                showWithActivity()
            }
        }
    }

    // MARK: - Hover In: dot → circle → pill → icons spread from center

    private func hoverIn() {
        cancelCollapse()
        cancelPendingTransitionWork()
        let nonce = beginTransition()

        // Ensure pill is in tree and start from current state
        pillInTree = true
        pillOpacity = 1.0

        // Phase 0 → 1: dot → circle (fast)
        if pillPhase < 1 {
            withAnimation(.easeOut(duration: 0.15)) {
                pillPhase = 1
            }
        }

        // Phase 1 → 2: circle → full pill width (ease out — decelerating expansion)
        let advanceWork = DispatchWorkItem {
            guard transitionNonce == nonce else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                pillPhase = 2
            }

            // Layer 2: icons spread from center (after pill reaches full width)
            let spreadWork = DispatchWorkItem {
                guard transitionNonce == nonce else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    iconsSpread = true
                }
            }
            iconSpreadWork = spreadWork
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: spreadWork)
        }
        phaseAdvanceWork = advanceWork
        DispatchQueue.main.asyncAfter(deadline: .now() + (pillPhase < 1 ? 0.15 : 0.0), execute: advanceWork)
    }

    // MARK: - Hover Out: icons retract → pill → circle → dot → fade

    private func hoverOut() {
        cancelCollapse()
        cancelPendingTransitionWork()
        let nonce = beginTransition()

        // If still has active providers, just retract to activity state (icons visible, pill stays)
        if hasIcons {
            // Retract hover-only icons, keep active ones
            withAnimation(.easeIn(duration: 0.2)) {
                iconsSpread = false
            }
            let restoreWork = DispatchWorkItem {
                guard transitionNonce == nonce, !isExpanded else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    iconsSpread = true  // re-spread with just active providers
                }
            }
            iconRestoreWork = restoreWork
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: restoreWork)
            return
        }

        // No active providers — full collapse sequence

        // Step 1: retract icons to center (ease in — accelerating retraction)
        withAnimation(.easeIn(duration: 0.2)) {
            iconsSpread = false
        }

        // Step 2: pill → circle
        let work = DispatchWorkItem {
            guard transitionNonce == nonce else { return }
            withAnimation(.easeIn(duration: 0.2)) {
                pillPhase = 1
            }

            // Step 3: circle → dot (implode)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                guard transitionNonce == nonce else { return }
                withAnimation(.easeIn(duration: 0.15)) {
                    pillPhase = 0
                }

                // Step 4: fade out dot
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard transitionNonce == nonce else { return }
                    withAnimation(.easeIn(duration: 0.15)) {
                        pillOpacity = 0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        guard transitionNonce == nonce else { return }
                        pillInTree = false
                    }
                }
            }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    // MARK: - Activity-driven show (no hover, provider becomes active)

    private func showWithActivity() {
        cancelCollapse()
        cancelPendingTransitionWork()
        let nonce = beginTransition()
        pillInTree = true
        pillOpacity = 1.0

        // Quick: dot → circle → pill
        withAnimation(.easeOut(duration: 0.12)) {
            pillPhase = 1
        }
        let advanceWork = DispatchWorkItem {
            guard transitionNonce == nonce else { return }
            withAnimation(.easeOut(duration: 0.22)) {
                pillPhase = 2
            }
            let spreadWork = DispatchWorkItem {
                guard transitionNonce == nonce else { return }
                withAnimation(.easeOut(duration: 0.22)) {
                    iconsSpread = true
                }
            }
            iconSpreadWork = spreadWork
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: spreadWork)
        }
        phaseAdvanceWork = advanceWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: advanceWork)
    }

    // MARK: - Activity-driven hide (no hover, provider goes idle)

    private func activityOut() {
        cancelPendingTransitionWork()
        let nonce = beginTransition()

        // Step 1: retract icons
        withAnimation(.easeIn(duration: 0.2)) {
            iconsSpread = false
        }

        let work = DispatchWorkItem {
            guard transitionNonce == nonce else { return }
            // Step 2: pill → circle
            withAnimation(.easeIn(duration: 0.2)) {
                pillPhase = 1
            }
            // Step 3: circle → dot → fade
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                guard transitionNonce == nonce else { return }
                withAnimation(.easeIn(duration: 0.15)) {
                    pillPhase = 0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard transitionNonce == nonce else { return }
                    withAnimation(.easeIn(duration: 0.15)) {
                        pillOpacity = 0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        guard transitionNonce == nonce else { return }
                        pillInTree = false
                    }
                }
            }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    // MARK: - Cancel pending collapse

    private func cancelCollapse() {
        collapseWork?.cancel()
        collapseWork = nil
    }

    private func cancelPendingTransitionWork() {
        phaseAdvanceWork?.cancel()
        phaseAdvanceWork = nil
        iconSpreadWork?.cancel()
        iconSpreadWork = nil
        iconRestoreWork?.cancel()
        iconRestoreWork = nil
    }

    @discardableResult
    private func beginTransition() -> Int {
        transitionNonce += 1
        return transitionNonce
    }

    // MARK: - Expand / Collapse dropdown

    private func openExpanded() {
        #if DEBUG
        print("[ExternalMonitorView] openExpanded: isExpanded=\(isExpanded), contentVisible=\(contentVisible)")
        #endif
        cancelCollapse()
        cancelPendingTransitionWork()
        let nonce = beginTransition()
        closeWork?.cancel()
        closeWork = nil

        // Force-reset: interrupt any in-progress close animation
        contentVisible = false
        isExpanded = false

        // Ensure pill is in tree and fully expanded before opening dropdown.
        pillInTree = true
        pillOpacity = 1.0
        pillPhase = 2
        iconsSpread = false

        // Give SwiftUI one render pass to create the pill view, then expand
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard transitionNonce == nonce else { return }
            withAnimation(.smooth(duration: 0.4)) {
                self.isExpanded = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard transitionNonce == nonce else { return }
                withAnimation(.easeOut(duration: 0.2)) { self.contentVisible = true }
            }
        }
    }

    private func closeExpanded() {
        #if DEBUG
        print("[ExternalMonitorView] closeExpanded: isExpanded=\(isExpanded)")
        #endif
        guard isExpanded else { return }
        isEditMode = false
        cancelPendingTransitionWork()
        let nonce = beginTransition()
        closeWork?.cancel()

        withAnimation(.easeIn(duration: 0.15)) { contentVisible = false }

        let work = DispatchWorkItem {
            guard transitionNonce == nonce else { return }
            withAnimation(.smooth(duration: 0.35)) { self.isExpanded = false }
            // After dropdown closes, restore pill to hover/active state
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard transitionNonce == nonce else { return }
                if self.isHovered {
                    // Re-trigger full hover-in so hover animations work correctly
                    self.hoverIn()
                } else if self.hasIcons {
                    self.pillPhase = 2
                    withAnimation(.easeOut(duration: 0.22)) {
                        self.iconsSpread = true
                    }
                } else {
                    self.activityOut()
                }
            }
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    // MARK: - Icons layout (center-outward spread)

    @ViewBuilder
    private var iconsView: some View {
        HStack(spacing: iconGap) {
            ForEach(Array(visibleProviders.enumerated()), id: \.element) { idx, provider in
                if let usage = registry.usageMap[provider] {
                    let centerIdx = visibleProviders.count / 2
                    let distFromCenter = abs(idx - centerIdx)

                    WingIconView(usage: usage)
                        .opacity(iconsSpread ? 1 : 0)
                        .scaleEffect(iconsSpread ? 1.0 : 0.3)
                        .animation(
                            .easeOut(duration: 0.22).delay(Double(distFromCenter) * staggerStep),
                            value: iconsSpread
                        )
                }
            }
        }
        .padding(.horizontal, sidePadding)
    }
}
