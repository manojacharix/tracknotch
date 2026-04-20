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
private let expandedWidth:  CGFloat = 380
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
        if isExpanded { return expandedWidth }
        guard let geo else { return geo?.notchWidth ?? 0 }
        return leftWingWidth + geo.notchWidth + rightWingWidth
    }

    private var pillLeadingOffset: CGFloat {
        if isExpanded { return (geo.map { $0.leftWingWidth + $0.notchWidth + $0.rightWingWidth } ?? expandedWidth) / 2 - expandedWidth / 2 }
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
            openExpanded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .notchCollapseDropdown)) { _ in
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
        iconsVisible = false
        pillExpanded = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { pillExpanded = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + iconExpandDelay) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { iconsVisible = true }
            }
        }
    }

    private func collapse() {
        iconsVisible = false
        let iconsDone = Double(max(leftProviders.count, rightProviders.count)) * staggerStep + 0.30
        DispatchQueue.main.asyncAfter(deadline: .now() + iconsDone) {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) { pillExpanded = false }
        }
    }

    // MARK: - Toggle expansion (called by NotchWindow on click)

    func openExpanded() {
        guard !isExpanded else { return }
        // Fade icons out, then grow shape and fade content in
        withAnimation(.easeOut(duration: 0.12)) { iconsVisible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                isExpanded = true
                pillExpanded = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                withAnimation(.easeOut(duration: 0.2)) { contentVisible = true }
            }
        }
    }

    func closeExpanded() {
        guard isExpanded else { return }
        isEditMode = false
        // Fade content out, then shrink shape back to pill, then restore wing icons
        withAnimation(.easeInOut(duration: 0.18)) { contentVisible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.spring(response: 0.48, dampingFraction: 0.88)) { isExpanded = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                if shouldShow { expand() }
            }
        }
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
                .animation(.spring(response: 0.45, dampingFraction: 0.82), value: pillWidth)
                .animation(.spring(response: 0.45, dampingFraction: 0.82), value: notchShapeHeight)
                .animation(.spring(response: 0.45, dampingFraction: 0.82), value: isExpanded)

            // Wing icons (idle/hover state) — hidden while expanded
            if iconsVisible && !isExpanded {
                wingContent(geo: geo)
                    .frame(width: pillWidth, height: pillHeight)
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
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: pillLeadingOffset)
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

    var body: some View {
        WingIconView(usage: usage)
            .opacity(visible ? 1 : 0)
            .offset(x: visible ? 0 : hiddenOffset)
            .onAppear {
                visible = false
                DispatchQueue.main.asyncAfter(deadline: .now() + expandDelay) {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) { visible = true }
                }
            }
            .onChange(of: isShowing) { showing in
                if !showing {
                    DispatchQueue.main.asyncAfter(deadline: .now() + collapseDelay) {
                        withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) { visible = false }
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

// MARK: - Pulsing add button

struct PulsingAddButton: View {
    @State private var isPulsing = false

    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white.opacity(isPulsing ? 0.9 : 0.35))
            .frame(width: 20, height: 20)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { pulse() }
            }
    }

    private func pulse() {
        withAnimation(.easeInOut(duration: 0.6)) { isPulsing = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            withAnimation(.easeInOut(duration: 0.6)) { isPulsing = false }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { pulse() }
    }
}
