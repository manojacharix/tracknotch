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
    @EnvironmentObject var windowHoverState: WindowHoverState

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
    /// Reentry guard: prevents openExpanded/closeExpanded from stomping each other
    /// during async animation sequences. True while an expand or collapse is in flight.
    @State private var dropdownTransitioning: Bool = false

    private var isHovered: Bool { windowHoverState.isHovered }

    // Idle: only active/lingering providers. Hover: all connected with usage data.
    private var visibleProviders: [LLMProvider] {
        if isHovered || isExpanded {
            return registry.connectedProviders.filter { registry.usageMap[$0] != nil }
        }
        return registry.activeProviders
    }

    private var hasIcons: Bool { !visibleProviders.isEmpty }
    /// True when hovered but no providers are connected — show + icon to invite setup.
    private var showPlusIcon: Bool { (isHovered || isExpanded) && registry.connectedProviders.isEmpty }

    // MARK: - Pill sizing

    private var targetPillWidth: CGFloat {
        if showPlusIcon { return circleSize + sidePadding * 2 }
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
                .frame(
                    width: frameReporter.panelFitsVisibleShape ? extExpandedWidth : trackNotchWindowWidth,
                    height: frameReporter.panelFitsVisibleShape ? shapeHeight : trackNotchWindowHeight
                )
                .allowsHitTesting(false)

            if pillInTree {
                ZStack(alignment: .top) {
                    // Black fill — clipped to shape so content can't overflow
                    Color.black

                    // Icons — visible when pill is fully open and not in dropdown
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
                        .frame(width: extExpandedWidth, height: extPillHeight)
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
                        .frame(width: extExpandedWidth)
                    }
                }
                // Clip all content to the shape — keeps corners clean
                .clipShape(
                    pillPhase >= 2
                        ? AnyShape(NotchShape(
                            topCornerRadius: isExpanded ? extExpandedTopRadius : 6,
                            bottomCornerRadius: isExpanded ? extExpandedBottomRadius : pillCornerRadius))
                        : AnyShape(RoundedRectangle(cornerRadius: pillRadius))
                )
                .frame(width: isExpanded ? extExpandedWidth : pillWidth,
                       height: shapeHeight, alignment: .top)
                .animation(
                    isExpanded
                        ? .interactiveSpring(response: 0.52, dampingFraction: 0.72, blendDuration: 0.1)
                        : .easeIn(duration: 0.28),
                    value: isExpanded
                )
                .animation(
                    isExpanded
                        ? .interactiveSpring(response: 0.52, dampingFraction: 0.72, blendDuration: 0.1)
                        : .easeIn(duration: 0.28),
                    value: shapeHeight
                )
                // Single animation keyed on pillPhase drives width, height, and cornerRadius
                // in lockstep — prevents the brief rectangular flash that occurs when
                // independent value: animations desync across the circle→dot transition.
                .animation(.easeInOut(duration: 0.22), value: pillPhase)
                .animation(.easeInOut(duration: 0.2), value: pillOpacity)
                .opacity(pillOpacity)
                .allowsHitTesting(isExpanded)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .notchExpandDropdown)) { _ in
            openExpanded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .notchCollapseDropdown)) { _ in
            // Force-close even if transitioning — NotchWindow has already reset its
            // isDropdownVisible flag and must stay in sync with SwiftUI isExpanded.
            // Bump nonce first so any in-flight open work item aborts, then clear
            // the transitioning guard so closeExpanded() is not blocked.
            if dropdownTransitioning {
                beginTransition()   // cancels pending open work items via nonce check
                dropdownTransitioning = false
            }
            // If still in mid-open (isExpanded=false), just reset state directly.
            if !isExpanded {
                contentVisible = false
                pillPhase = hasIcons ? 2 : 0
                if !hasIcons { pillInTree = false }
            } else {
                closeExpanded()
            }
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
        guard !dropdownTransitioning else { return }
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
        // While dropdown is opening or closing, hover-out must not touch the
        // transition nonce — doing so would invalidate the pending work items
        // and leave the dropdown half-open with ignoresMouseEvents=true stuck on.
        guard !dropdownTransitioning else { return }
        cancelCollapse()
        cancelPendingTransitionWork()
        let nonce = beginTransition()

        // If still has active providers, pill stays visible — no animation needed.
        // Don't touch iconsSpread here; toggling it false→true triggers onChange(of: hasIcons)
        // which calls showWithActivity() and creates an animation loop.
        if hasIcons {
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
        guard !dropdownTransitioning else { return }
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
        guard !dropdownTransitioning else { return }
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
        // No providers connected — open settings directly instead of empty dropdown
        if registry.connectedProviders.isEmpty {
            ConnectionWindowController.shared.open()
            return
        }
        // Already expanded or mid-open — nothing to do
        guard !isExpanded && !dropdownTransitioning else { return }

        dropdownTransitioning = true
        cancelCollapse()
        cancelPendingTransitionWork()
        let nonce = beginTransition()
        closeWork?.cancel()
        closeWork = nil

        // Ensure pill is in tree and fully expanded before opening dropdown.
        // Do NOT reset isExpanded=false here — that creates a window where
        // closeExpanded's guard (guard isExpanded else { return }) passes,
        // and any queued collapse notification triggers a spurious close
        // before the 50ms open fires, causing the open→close loop.
        contentVisible = false
        pillInTree = true
        pillOpacity = 1.0
        pillPhase = 2
        iconsSpread = false

        // Small delay so SwiftUI commits the pill-state reset before the spring fires.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard self.transitionNonce == nonce else {
                self.dropdownTransitioning = false
                return
            }
            withAnimation(.interactiveSpring(response: 0.52, dampingFraction: 0.72, blendDuration: 0.1)) {
                self.isExpanded = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                guard self.transitionNonce == nonce else { return }
                withAnimation(.easeOut(duration: 0.2)) { self.contentVisible = true }
                self.dropdownTransitioning = false
            }
        }
    }

    private func closeExpanded() {
        guard isExpanded && !dropdownTransitioning else { return }

        dropdownTransitioning = true
        isEditMode = false
        cancelPendingTransitionWork()
        let nonce = beginTransition()
        closeWork?.cancel()

        withAnimation(.easeInOut(duration: 0.18)) { contentVisible = false }

        let work = DispatchWorkItem {
            guard self.transitionNonce == nonce else {
                self.dropdownTransitioning = false
                return
            }
            withAnimation(.easeIn(duration: 0.28)) { self.isExpanded = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard self.transitionNonce == nonce else {
                    self.dropdownTransitioning = false
                    return
                }
                self.dropdownTransitioning = false
                // Restore pill to correct post-close state without calling hoverIn()
                // (hoverIn re-triggers onChange chains that can loop).
                if self.hasIcons || self.isHovered {
                    self.pillPhase = 2
                    self.iconsSpread = false
                    withAnimation(.easeOut(duration: 0.22)) {
                        self.iconsSpread = true
                    }
                } else {
                    self.activityOut()
                }
            }
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    // MARK: - Icons layout (center-outward spread)

    @ViewBuilder
    private var iconsView: some View {
        if showPlusIcon {
            // No providers connected — show + to invite setup
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .opacity(iconsSpread ? 1 : 0)
                .scaleEffect(iconsSpread ? 1.0 : 0.3)
                .animation(.easeOut(duration: 0.22), value: iconsSpread)
                .onTapGesture { ConnectionWindowController.shared.open() }
        } else {
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
}
