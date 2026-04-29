import SwiftUI

private let iconSize: CGFloat         = 22
private let iconGap: CGFloat          = 8
private let outerSidePadding: CGFloat = 12
private let innerSidePadding: CGFloat = 10

// Timing constants
private let pillExpandDelay:   Double = 0.0
private let iconExpandDelay:   Double = 0.12
private let iconCollapseDelay: Double = 0.0
private let pillCollapseDelay: Double = 0.18
private let staggerStep:       Double = 0.05

// Expanded notch dimensions
private let expandedMaxWidth:  CGFloat = 380
private let expandedTopRadius:    CGFloat = 10
private let expandedBottomRadius: CGFloat = 26

struct NotchRootView: View {
    let mode: NotchMode
    let onToggleDropdown: () -> Void

    @EnvironmentObject var registry: ProviderRegistry
    @State private var geo: NotchGeometry? = nil

    @State private var iconsVisible: Bool = false
    @State private var pillExpanded: Bool = false

    // Dropdown expansion state
    @State private var isExpanded: Bool = false
    @State private var contentVisible: Bool = false
    @State private var isEditMode: Bool = false
    @State private var transitionNonce: Int = 0
    @State private var expandIconsWork: DispatchWorkItem? = nil
    @State private var collapsePillWork: DispatchWorkItem? = nil
    @State private var openExpandWork: DispatchWorkItem? = nil
    @State private var openContentWork: DispatchWorkItem? = nil
    @State private var closeCollapseWork: DispatchWorkItem? = nil
    @State private var closeRestoreWork: DispatchWorkItem? = nil

    private var isHovered: Bool { registry.isExternalHovered }

    private var targetProviders: [LLMProvider] {
        if isHovered || isExpanded {
            return registry.connectedProviders.filter { registry.usageMap[$0] != nil }
        }
        return registry.activeProviders
    }

    private var leftProviders:  [LLMProvider] { targetProviders.filter { $0.notchWing == .left } }
    private var rightProviders: [LLMProvider] { targetProviders.filter { $0.notchWing == .right } }

    private func wingWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * iconSize + CGFloat(count - 1) * iconGap + outerSidePadding + innerSidePadding
    }

    private var leftWingWidth:  CGFloat { pillExpanded && !isExpanded ? wingWidth(count: leftProviders.count) : 0 }
    private var rightWingWidth: CGFloat { pillExpanded && !isExpanded ? wingWidth(count: rightProviders.count) : 0 }
    private var pillHeight: CGFloat { geo?.notchHeight ?? 39 }

    private var pillWidth: CGFloat {
        if isExpanded { return expandedMaxWidth }
        guard let geo else { return geo?.notchWidth ?? 0 }
        return leftWingWidth + geo.notchWidth + rightWingWidth
    }

    private var pillLeadingOffset: CGFloat {
        if isExpanded { return (geo.map { $0.leftWingWidth + $0.notchWidth + $0.rightWingWidth } ?? expandedMaxWidth) / 2 - expandedMaxWidth / 2 }
        guard let geo else { return 0 }
        return geo.leftWingWidth - leftWingWidth
    }

    // Expanded height = content + notch bar height so the shape grows downward from notch bottom
    @State private var expandedContentHeight: CGFloat = 200

    private var notchShapeHeight: CGFloat {
        isExpanded ? pillHeight + expandedContentHeight : pillHeight
    }

    private var shouldShow: Bool { isHovered || !registry.activeProviders.isEmpty || isExpanded }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: geo.map { $0.leftWingWidth + $0.notchWidth + $0.rightWingWidth } ?? 580,
                       height: trackNotchWindowHeight)
                .allowsHitTesting(false)

            if let geo {
                pillView(geo: geo)
            }
        }
        .onAppear {
            Task { @MainActor in geo = notchGeometry() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .notchExpandDropdown)) { _ in
            #if DEBUG
            print("[NotchRootView] received notchExpandDropdown")
            #endif
            openExpanded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .notchCollapseDropdown)) { _ in
            #if DEBUG
            print("[NotchRootView] received notchCollapseDropdown")
            #endif
            closeExpanded()
        }
        .onChange(of: shouldShow) { show in
            if show { expand() } else { collapse() }
        }
        .onChange(of: targetProviders.count) { _ in
            if shouldShow && pillExpanded && !isExpanded {
                iconsVisible = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                        iconsVisible = true
                    }
                }
            }
        }
    }

    private func expand() {
        cancelPendingWork()
        let nonce = beginTransition()
        iconsVisible = false
        pillExpanded = false
        withAnimation(.interactiveSpring(response: 0.38, dampingFraction: 0.82, blendDuration: 0.1)) { pillExpanded = true }
        let work = DispatchWorkItem {
            guard transitionNonce == nonce else { return }
            withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.78, blendDuration: 0.08)) { iconsVisible = true }
        }
        expandIconsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + iconExpandDelay, execute: work)
    }

    private func collapse() {
        cancelPendingWork()
        let nonce = beginTransition()
        // Step 1: dissolve icons in place (opacity fade, no movement)
        withAnimation(.easeOut(duration: 0.25)) {
            iconsVisible = false
        }
        // Step 2: after icons fully dissolve, shrink pill back into notch
        let work = DispatchWorkItem {
            guard transitionNonce == nonce else { return }
            withAnimation(.easeInOut(duration: 0.30)) {
                pillExpanded = false
            }
        }
        collapsePillWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30, execute: work)
    }

    // MARK: - Toggle expansion (called by NotchWindow on click)

    func openExpanded() {
        #if DEBUG
        print("[NotchRootView] openExpanded: isExpanded=\(isExpanded), contentVisible=\(contentVisible)")
        #endif
        cancelPendingWork()
        let nonce = beginTransition()
        // Already fully expanded with content visible — no-op
        if isExpanded && contentVisible { return }
        // Fade icons out, then grow shape and fade content in
        withAnimation(.easeOut(duration: 0.12)) { iconsVisible = false }
        let expandWork = DispatchWorkItem { [self] in
            guard transitionNonce == nonce else { return }
            withAnimation(.interactiveSpring(response: 0.5, dampingFraction: 0.85, blendDuration: 0.12)) {
                isExpanded = true
                pillExpanded = true
            }
            let contentWork = DispatchWorkItem { [self] in
                guard transitionNonce == nonce else { return }
                withAnimation(.easeOut(duration: 0.2)) { contentVisible = true }
            }
            openContentWork = contentWork
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: contentWork)
        }
        openExpandWork = expandWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: expandWork)
    }

    func closeExpanded() {
        #if DEBUG
        print("[NotchRootView] closeExpanded: isExpanded=\(isExpanded)")
        #endif
        guard isExpanded else { return }
        cancelPendingWork()
        let nonce = beginTransition()
        isEditMode = false
        // Fade content out, then shrink shape back to pill, then restore wing icons
        withAnimation(.easeInOut(duration: 0.18)) { contentVisible = false }
        let collapseWork = DispatchWorkItem {
            guard transitionNonce == nonce else { return }
            withAnimation(.interactiveSpring(response: 0.48, dampingFraction: 0.88, blendDuration: 0.1)) { isExpanded = false }
            let restoreWork = DispatchWorkItem {
                guard transitionNonce == nonce else { return }
                if shouldShow { expand() }
            }
            closeRestoreWork = restoreWork
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30, execute: restoreWork)
        }
        closeCollapseWork = collapseWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: collapseWork)
    }

    private func cancelPendingWork() {
        expandIconsWork?.cancel()
        expandIconsWork = nil
        collapsePillWork?.cancel()
        collapsePillWork = nil
        openExpandWork?.cancel()
        openExpandWork = nil
        openContentWork?.cancel()
        openContentWork = nil
        closeCollapseWork?.cancel()
        closeCollapseWork = nil
        closeRestoreWork?.cancel()
        closeRestoreWork = nil
    }

    @discardableResult
    private func beginTransition() -> Int {
        transitionNonce += 1
        return transitionNonce
    }

    // MARK: - Pill

    @ViewBuilder
    private func pillView(geo: NotchGeometry) -> some View {
        let totalWidth = geo.leftWingWidth + geo.notchWidth + geo.rightWingWidth

        ZStack(alignment: .top) {
            // The single notch shape — animates between pill and expanded card
            NotchShape(topCornerRadius: isExpanded ? expandedTopRadius : 6,
                       bottomCornerRadius: isExpanded ? expandedBottomRadius : 14)
                .fill(Color.black)
                .frame(width: pillWidth, height: notchShapeHeight)
                .shadow(color: .black.opacity(isExpanded ? 0.7 : 0.5),
                        radius: isExpanded ? 24 : 8,
                        y: isExpanded ? 10 : 0)
                .animation(.interactiveSpring(response: 0.45, dampingFraction: 0.82, blendDuration: 0.1), value: pillWidth)
                .animation(.interactiveSpring(response: 0.45, dampingFraction: 0.82, blendDuration: 0.1), value: notchShapeHeight)
                .animation(.interactiveSpring(response: 0.45, dampingFraction: 0.82, blendDuration: 0.1), value: isExpanded)

            // Wing icons (idle/hover state) — hidden while expanded
            // Always in tree while pill is expanded so child dissolve animations can play
            if pillExpanded && !isExpanded {
                wingContent(geo: geo)
                    .frame(width: pillWidth, height: pillHeight)
                    .allowsHitTesting(false)
            }

            // When expanded: edit (left) and settings (right) flanking the notch.
            // Use the physical notch width as the centre gap so both buttons
            // sit symmetrically in the wing zones on either side.
            if isExpanded {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)

                    // Edit button — right side of left wing, close to notch
                    ZStack {
                        Button(isEditMode ? "done" : "edit") {
                            isEditMode.toggle()
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                        .contentShape(Capsule())
                    }
                    .padding(.trailing, 10)

                    // Physical notch gap — tap to close dropdown
                    Color.white.opacity(0.001)
                        .frame(width: geo.notchWidth, height: pillHeight)
                        .contentShape(Rectangle())
                        .onTapGesture { onToggleDropdown() }

                    // Settings button — left side of right wing, close to notch
                    ZStack {
                        Button("settings") {
                            ConnectionWindowController.shared.open()
                            onToggleDropdown()
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                        .contentShape(Capsule())
                    }
                    .padding(.leading, 10)

                    Spacer(minLength: 0)
                }
                .frame(width: pillWidth, height: pillHeight)
                .opacity(contentVisible ? 1 : 0)
            }

            // Expanded dropdown content — sits below the notch bar inside the shape
            if isExpanded {
                VStack(spacing: 0) {
                    // Spacer for the physical notch bar height
                    Color.clear.frame(height: pillHeight)

                    DropdownContent(onDismiss: { onToggleDropdown() }, isEditMode: $isEditMode)
                        .padding(.top, 8)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 8)
                        .opacity(contentVisible ? 1 : 0)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.onAppear {
                                    expandedContentHeight = proxy.size.height
                                }.onChange(of: proxy.size.height) { h in
                                    expandedContentHeight = h
                                }
                            }
                        )
                }
                .frame(width: pillWidth)
                .clipped()
            }
        }
        .frame(width: pillWidth, height: notchShapeHeight, alignment: .top)
        .offset(x: pillLeadingOffset)
        .animation(.interactiveSpring(response: 0.45, dampingFraction: 0.82, blendDuration: 0.1), value: pillLeadingOffset)
        // Pass all events through to StripPanel when collapsed; interactive when expanded
        .allowsHitTesting(isExpanded)
    }

    // MARK: - Wing content

    @ViewBuilder
    private func wingContent(geo: NotchGeometry) -> some View {
        HStack(spacing: 0) {
            if !leftProviders.isEmpty {
                HStack(spacing: iconGap) {
                    Spacer(minLength: 0)
                    ForEach(Array(leftProviders.enumerated()), id: \.element) { idx, provider in
                        if let usage = registry.usageMap[provider] {
                            let expandDelay   = Double(leftProviders.count - 1 - idx) * staggerStep
                            let collapseDelay = Double(idx) * staggerStep
                            NotchSlideIcon(usage: usage, direction: .right,
                                           expandDelay: expandDelay, collapseDelay: collapseDelay,
                                           isShowing: iconsVisible)
                        }
                    }
                }
                .padding(.leading, outerSidePadding)
                .padding(.trailing, innerSidePadding)
                .frame(width: leftWingWidth, height: pillHeight, alignment: .center)
                .clipped()
            }

            Color.clear.frame(width: geo.notchWidth, height: pillHeight)

            if !rightProviders.isEmpty {
                HStack(spacing: iconGap) {
                    ForEach(Array(rightProviders.enumerated()), id: \.element) { idx, provider in
                        if let usage = registry.usageMap[provider] {
                            let expandDelay   = Double(idx) * staggerStep
                            let collapseDelay = Double(rightProviders.count - 1 - idx) * staggerStep
                            NotchSlideIcon(usage: usage, direction: .left,
                                           expandDelay: expandDelay, collapseDelay: collapseDelay,
                                           isShowing: iconsVisible)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, innerSidePadding)
                .padding(.trailing, outerSidePadding)
                .frame(width: rightWingWidth, height: pillHeight, alignment: .center)
                .clipped()
            }
        }
    }
}

// MARK: - NotchSlideIcon

private enum SlideDirection { case left, right }

private struct NotchSlideIcon: View {
    let usage: ProviderUsage
    let direction: SlideDirection
    let expandDelay: Double
    let collapseDelay: Double
    let isShowing: Bool

    @State private var visible = false
    private let slideDistance: CGFloat = 36

    private var hiddenOffset: CGFloat {
        direction == .right ? slideDistance : -slideDistance
    }

    @State private var dissolved = false

    var body: some View {
        WingIconView(usage: usage)
            .opacity(visible && !dissolved ? 1 : 0)
            .offset(x: visible ? 0 : hiddenOffset)
            .onAppear {
                visible = false
                dissolved = false
                DispatchQueue.main.asyncAfter(deadline: .now() + expandDelay) {
                    withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.78, blendDuration: 0.08)) { visible = true }
                }
            }
            .onChange(of: isShowing) { showing in
                if showing {
                    visible = false
                    dissolved = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + expandDelay) {
                        withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.78, blendDuration: 0.08)) { visible = true }
                    }
                } else {
                    // Dissolve in place (opacity only, no slide)
                    withAnimation(.easeOut(duration: 0.25)) {
                        dissolved = true
                    }
                }
            }
    }
}

// MARK: - Previews

#Preview("Pill shape") {
    ZStack(alignment: .top) {
        Color.white.opacity(0.15)
        NotchShape(topCornerRadius: 6, bottomCornerRadius: 14)
            .fill(Color.black)
            .frame(width: 200, height: 39)
            .overlay {
                NotchShape(topCornerRadius: 6, bottomCornerRadius: 14)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            }
    }
    .frame(width: 600, height: 60)
    .background(Color.gray.opacity(0.4))
}

#Preview("Wing active") {
    let usage = ProviderUsage(
        provider: .claudeCode, billingType: .subscription, window: .weekly,
        percentage: 45, resetsAt: nil, tokensUsed: 50000, tokensLimit: 2500000,
        costUsedUSD: nil, costLimitUSD: nil, modelBreakdown: [], fetchedAt: Date(),
        isActivelyConsuming: true
    )
    return ZStack(alignment: .top) {
        Color.white.opacity(0.15)
        HStack(spacing: 0) {
            Spacer()
            NotchShape(topCornerRadius: 6, bottomCornerRadius: 14)
                .fill(Color.black)
                .frame(width: 244, height: 39)
                .overlay {
                    HStack {
                        Spacer().frame(width: 210)
                        WingIconView(usage: usage)
                    }
                }
            Spacer()
        }
    }
    .frame(width: 600, height: 60)
    .background(Color.gray.opacity(0.4))
}
