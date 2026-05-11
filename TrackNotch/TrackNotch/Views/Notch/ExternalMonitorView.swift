import SwiftUI

// MARK: - External Monitor overlay
//
// Two-layer animation model:
//   Layer 1 — Pill shape: animates width/height/cornerRadius directly as @State CGFloat vars
//   Layer 2 — Icons: burst from center outward on spread, retract to center on collapse
//
// Hover-in:  dot → circle → pill expands → icons burst from center to positions
// Hover-out: icons retract to center → pill contracts → circle → dot → fade

private let iconSize:         CGFloat = 22
private let iconGap:          CGFloat = 8
private let sidePadding:      CGFloat = 16
private let extPillHeight:    CGFloat = 32
private let pillCornerRadius: CGFloat = 14
private let dotSize:          CGFloat = 8
private let circleSize:       CGFloat = 32

// Expanded dropdown dimensions
private let extExpandedMaxWidth:       CGFloat = 380
private let extExpandedTopRadius:      CGFloat = 10
private let extExpandedBottomRadius:   CGFloat = 26

struct ExternalMonitorView: View {
    @EnvironmentObject var registry: ProviderRegistry
    @EnvironmentObject var frameReporter: DropdownFrameReporter
    @EnvironmentObject var windowHoverState: WindowHoverState

    private var extExpandedWidth: CGFloat {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return extExpandedMaxWidth }
        return min(extExpandedMaxWidth, screen.frame.width - 40)
    }

    // MARK: - Pill animated dimensions (driven directly, not computed from phase Int)
    // Using explicit @State vars means withAnimation() interpolates these smoothly
    // without any computed-var snap at the moment the animation starts.

    @State private var pillInTree: Bool    = false
    @State private var pillW:      CGFloat = dotSize
    @State private var pillH:      CGFloat = dotSize
    @State private var pillR:      CGFloat = dotSize / 2
    @State private var pillOpacity: Double = 0

    // pillPhase is kept only as a logical marker (not used for sizing) so we
    // can still gate "is pill at full width" without comparing floats.
    // 0 = dot, 1 = circle, 2 = full pill
    @State private var pillPhase: Int = 0

    // Whether to use NotchShape (true when pill is at full width) vs RoundedRectangle.
    // NotchShape has inward top corners — only valid at pill phase, not circle/dot.
    @State private var useNotchShape: Bool = false

    // MARK: - Icons
    @State private var iconsSpread: Bool = false

    // MARK: - Sequencing
    @State private var collapseWork:      DispatchWorkItem? = nil
    @State private var closeWork:         DispatchWorkItem? = nil
    @State private var phaseAdvanceWork:  DispatchWorkItem? = nil
    @State private var iconSpreadWork:    DispatchWorkItem? = nil
    @State private var iconRestoreWork:   DispatchWorkItem? = nil

    // MARK: - Dropdown
    @State private var isExpanded:           Bool    = false
    @State private var contentVisible:       Bool    = false
    @State private var isEditMode:           Bool    = false
    @State private var expandedContentHeight: CGFloat = 200
    @State private var transitionNonce:      Int     = 0
    @State private var dropdownTransitioning: Bool   = false

    private var isHovered: Bool { windowHoverState.isHovered }

    private var visibleProviders: [LLMProvider] {
        if isHovered || isExpanded {
            return registry.connectedProviders.filter { registry.usageMap[$0] != nil }
        }
        return registry.activeProviders
    }

    private var hasIcons: Bool { !visibleProviders.isEmpty }
    private var showPlusIcon: Bool { (isHovered || isExpanded) && registry.connectedProviders.isEmpty }

    private var targetPillWidth: CGFloat {
        if showPlusIcon { return circleSize + sidePadding * 2 }
        let count = CGFloat(max(visibleProviders.count, 1))
        return count * iconSize + max(0, count - 1) * iconGap + sidePadding * 2
    }

    private var shapeHeight: CGFloat {
        isExpanded ? extPillHeight + expandedContentHeight : pillH
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
                // Layer 1: Clipped pill — black fill + expanded content only.
                ZStack(alignment: .top) {
                    Color.black

                    if isExpanded {
                        HStack {
                            Button(isEditMode ? "done" : "edit") { isEditMode.toggle() }
                                .buttonStyle(.borderless)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(0.7))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(Color.white.opacity(0.12)))
                                .contentShape(Capsule())

                            Spacer()

                            Button("settings") { ConnectionWindowController.shared.open() }
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
                                        Color.clear
                                            .onAppear {
                                                expandedContentHeight = proxy.size.height
                                                frameReporter.dropdownContentHeight = proxy.size.height
                                            }
                                            .onChange(of: proxy.size.height) { h in
                                                expandedContentHeight = h
                                                frameReporter.dropdownContentHeight = h
                                            }
                                    }
                                )
                        }
                        .frame(width: extExpandedWidth)
                    }

                    if isExpanded {
                        Color.white.opacity(0.001)
                            .frame(width: extExpandedWidth, height: extPillHeight)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                NotificationCenter.default.post(name: .notchCollapseDropdown, object: nil)
                            }
                            .frame(width: extExpandedWidth, height: shapeHeight, alignment: .top)
                    }
                }
                // NotchShape only at full pill phase — gives the inward top-corner "wing" look.
                // Circle and dot always use RoundedRectangle so cornerRadius animates smoothly.
                .clipShape(
                    isExpanded
                        ? AnyShape(NotchShape(topCornerRadius: extExpandedTopRadius,
                                              bottomCornerRadius: extExpandedBottomRadius))
                        : useNotchShape
                            ? AnyShape(NotchShape(topCornerRadius: 6, bottomCornerRadius: pillCornerRadius))
                            : AnyShape(RoundedRectangle(cornerRadius: pillR))
                )
                .frame(width: isExpanded ? extExpandedWidth : pillW,
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
                .opacity(pillOpacity)
                .allowsHitTesting(isExpanded)

                // Layer 2: Icons outside clip — animate freely without being cropped.
                if (pillPhase >= 2 || iconsSpread) && !isExpanded {
                    iconsView
                        .frame(width: targetPillWidth, height: extPillHeight)
                        .opacity(pillOpacity)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .onReceive(NotificationCenter.default.publisher(for: .notchExpandDropdown)) { _ in
            openExpanded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .notchCollapseDropdown)) { _ in
            if dropdownTransitioning {
                beginTransition()
                dropdownTransitioning = false
            }
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
            if hovered { hoverIn() } else { hoverOut() }
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
            if hasIcons { showWithActivity() }
        }
    }

    // MARK: - Helpers: set pill dimensions for each phase

    private func applyDotDimensions() {
        pillW = dotSize
        pillH = dotSize
        pillR = dotSize / 2
        pillPhase = 0
        useNotchShape = false
    }

    private func applyCircleDimensions() {
        pillW = circleSize
        pillH = circleSize
        pillR = circleSize / 2
        pillPhase = 1
        useNotchShape = false
    }

    private func applyPillDimensions() {
        pillW = targetPillWidth
        pillH = extPillHeight
        pillR = pillCornerRadius
        pillPhase = 2
        useNotchShape = true
    }

    // MARK: - Hover In

    private func hoverIn() {
        guard !dropdownTransitioning else { return }
        cancelCollapse()
        let nonce = beginTransition()

        if pillInTree && pillPhase >= 2 {
            pillOpacity = 1.0
            withAnimation(.easeOut(duration: 0.25)) { iconsSpread = true }
            return
        }

        cancelPendingTransitionWork()
        applyDotDimensions()
        pillOpacity = pillInTree ? pillOpacity : 0
        pillInTree = true

        let phase1Work = DispatchWorkItem {
            guard transitionNonce == nonce else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                pillOpacity = 1.0
                applyCircleDimensions()
            }
            let advanceWork = DispatchWorkItem {
                guard transitionNonce == nonce else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    applyPillDimensions()
                }
                let spreadWork = DispatchWorkItem {
                    guard transitionNonce == nonce else { return }
                    withAnimation(.easeOut(duration: 0.25)) { iconsSpread = true }
                }
                iconSpreadWork = spreadWork
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: spreadWork)
            }
            phaseAdvanceWork = advanceWork
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: advanceWork)
        }
        phaseAdvanceWork = phase1Work
        DispatchQueue.main.async(execute: phase1Work)
    }

    // MARK: - Hover Out

    private func hoverOut() {
        guard !dropdownTransitioning else { return }
        cancelCollapse()
        cancelPendingTransitionWork()
        let nonce = beginTransition()

        if hasIcons { return }

        // Step 1: icons retract to center
        withAnimation(.easeIn(duration: 0.2)) { iconsSpread = false }

        // Step 2: pill → circle (after icons finish retracting)
        let work = DispatchWorkItem {
            guard transitionNonce == nonce else { return }
            // Switch clip to RoundedRectangle before dimensions change,
            // so NotchShape never clips a circle/dot frame.
            useNotchShape = false
            pillPhase = 1
            withAnimation(.easeIn(duration: 0.22)) {
                applyCircleDimensions()
            }

            // Step 3: circle → dot
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                guard transitionNonce == nonce else { return }
                withAnimation(.easeIn(duration: 0.18)) {
                    applyDotDimensions()
                }

                // Step 4: fade out
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard transitionNonce == nonce else { return }
                    withAnimation(.easeIn(duration: 0.15)) { pillOpacity = 0 }
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

    // MARK: - Activity-driven show

    private func showWithActivity() {
        guard !dropdownTransitioning else { return }
        cancelCollapse()
        cancelPendingTransitionWork()
        let nonce = beginTransition()

        applyDotDimensions()
        pillOpacity = pillInTree ? pillOpacity : 0
        pillInTree = true

        let phase1Work = DispatchWorkItem {
            guard transitionNonce == nonce else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                pillOpacity = 1.0
                applyCircleDimensions()
            }
            let advanceWork = DispatchWorkItem {
                guard transitionNonce == nonce else { return }
                withAnimation(.easeOut(duration: 0.22)) { applyPillDimensions() }
                let spreadWork = DispatchWorkItem {
                    guard transitionNonce == nonce else { return }
                    withAnimation(.easeOut(duration: 0.22)) { iconsSpread = true }
                }
                iconSpreadWork = spreadWork
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: spreadWork)
            }
            phaseAdvanceWork = advanceWork
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: advanceWork)
        }
        phaseAdvanceWork = phase1Work
        DispatchQueue.main.async(execute: phase1Work)
    }

    // MARK: - Activity-driven hide

    private func activityOut() {
        guard !dropdownTransitioning else { return }
        cancelPendingTransitionWork()
        let nonce = beginTransition()

        withAnimation(.easeIn(duration: 0.2)) { iconsSpread = false }

        let work = DispatchWorkItem {
            guard transitionNonce == nonce else { return }
            useNotchShape = false
            pillPhase = 1
            withAnimation(.easeIn(duration: 0.22)) { applyCircleDimensions() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                guard transitionNonce == nonce else { return }
                withAnimation(.easeIn(duration: 0.18)) { applyDotDimensions() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard transitionNonce == nonce else { return }
                    withAnimation(.easeIn(duration: 0.15)) { pillOpacity = 0 }
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

    // MARK: - Cancel helpers

    private func cancelCollapse() {
        collapseWork?.cancel(); collapseWork = nil
    }

    private func cancelPendingTransitionWork() {
        phaseAdvanceWork?.cancel(); phaseAdvanceWork = nil
        iconSpreadWork?.cancel();   iconSpreadWork = nil
        iconRestoreWork?.cancel();  iconRestoreWork = nil
    }

    @discardableResult
    private func beginTransition() -> Int {
        transitionNonce += 1
        return transitionNonce
    }

    // MARK: - Expand / Collapse dropdown

    private func openExpanded() {
        if registry.connectedProviders.isEmpty {
            ConnectionWindowController.shared.open()
            return
        }
        guard !isExpanded && !dropdownTransitioning else { return }

        dropdownTransitioning = true
        cancelCollapse()
        cancelPendingTransitionWork()
        let nonce = beginTransition()
        closeWork?.cancel(); closeWork = nil

        contentVisible = false
        pillInTree = true
        pillOpacity = 1.0
        applyPillDimensions()
        iconsSpread = false

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
                if self.hasIcons || self.isHovered {
                    self.applyCircleDimensions()
                    self.iconsSpread = false
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.22)) { self.applyPillDimensions() }
                        let spreadWork = DispatchWorkItem {
                            guard self.transitionNonce == nonce else { return }
                            withAnimation(.easeOut(duration: 0.22)) { self.iconsSpread = true }
                        }
                        self.iconSpreadWork = spreadWork
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: spreadWork)
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
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .opacity(iconsSpread ? 1 : 0)
                .scaleEffect(iconsSpread ? 1.0 : 0.5)
                .animation(.easeOut(duration: 0.25), value: iconsSpread)
                .onTapGesture { ConnectionWindowController.shared.open() }
        } else {
            let providers = visibleProviders
            let count = providers.count
            let contentW = CGFloat(count) * iconSize + CGFloat(max(0, count - 1)) * iconGap
            let center = contentW / 2

            ZStack {
                ForEach(Array(providers.enumerated()), id: \.element) { idx, provider in
                    if let usage = registry.usageMap[provider] {
                        let iconCenter = CGFloat(idx) * (iconSize + iconGap) + iconSize / 2
                        let finalOffset = iconCenter - center

                        WingIconView(usage: usage)
                            .offset(x: iconsSpread ? finalOffset : 0)
                            .opacity(iconsSpread ? 1 : 0)
                            .scaleEffect(iconsSpread ? 1.0 : 0.4)
                            .animation(.easeOut(duration: 0.25), value: iconsSpread)
                    }
                }
            }
            .frame(width: contentW, height: iconSize)
        }
    }
}
