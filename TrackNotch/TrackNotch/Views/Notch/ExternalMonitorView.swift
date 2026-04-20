import SwiftUI

// MARK: - External Monitor overlay
//
// Three states:
//   Idle    → only actively-consuming providers shown, full brightness
//   Hover   → all connected providers with usage data shown (stats view), full brightness
//   Click   → dropdown expands below the pill
//
// Collapse sequence (notchless / external only):
//   1. Icons slide inward + fade out (staggered)
//   2. Pill shrinks slowly after icons are gone
//   3. Pill fades out as a dot

private let iconSize:         CGFloat = 22
private let iconGap:          CGFloat = 8
private let sidePadding:      CGFloat = 10
private let extPillHeight:    CGFloat = 32
private let pillCornerRadius: CGFloat = 16
private let staggerStep:      Double  = 0.06

// How long all icons take to finish their exit (stagger * maxIcons + icon animation duration)
private let iconExitDuration: Double  = 0.45

// Expanded dropdown dimensions
private let extExpandedWidth:        CGFloat = 380
private let extExpandedBottomRadius: CGFloat = 26

struct ExternalMonitorView: View {
    @EnvironmentObject var registry: ProviderRegistry

    // Separate pill visibility so it can linger after icons leave
    @State private var pillVisible: Bool = false
    @State private var pillCollapseTimer: Timer? = nil

    // Dropdown state
    @State private var isExpanded: Bool = false
    @State private var contentVisible: Bool = false
    @State private var isEditMode: Bool = false
    @State private var expandedContentHeight: CGFloat = 200

    private var isHovered: Bool { registry.isExternalHovered }

    // Idle: only active/lingering providers. Hover: all connected with usage data.
    private var visibleProviders: [LLMProvider] {
        if isHovered || isExpanded {
            return registry.connectedProviders.filter { registry.usageMap[$0] != nil }
        }
        return registry.activeProviders
    }

    private var hasIcons: Bool { !visibleProviders.isEmpty }

    // Split into left/right halves from center — left reversed so outermost is index 0
    private var leftProviders: [LLMProvider] {
        let half = visibleProviders.count / 2
        return Array(visibleProviders.prefix(half).reversed())
    }
    private var rightProviders: [LLMProvider] {
        let half = visibleProviders.count / 2
        return Array(visibleProviders.dropFirst(half))
    }

    // Pill width when icons present; dot size when collapsing empty
    private var collapsedPillWidth: CGFloat {
        guard hasIcons else { return 8 }
        let n = CGFloat(visibleProviders.count)
        return n * iconSize + max(0, n - 1) * iconGap + sidePadding * 2
    }

    private var shapeWidth: CGFloat {
        isExpanded ? extExpandedWidth : collapsedPillWidth
    }

    private var shapeHeight: CGFloat {
        isExpanded ? extPillHeight + expandedContentHeight : extPillHeight
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .frame(width: trackNotchWindowWidth, height: isExpanded ? trackNotchWindowHeight : externalPanelHeight)
                .allowsHitTesting(false)

            if pillVisible || isExpanded {
                ZStack(alignment: .top) {
                    // Shape — animates between pill and expanded card
                    RoundedRectangle(cornerRadius: isExpanded ? extExpandedBottomRadius : pillCornerRadius)
                        .fill(Color.black)
                        .frame(width: shapeWidth, height: shapeHeight)
                        .shadow(color: .black.opacity(isExpanded ? 0.7 : 0.4),
                                radius: isExpanded ? 24 : 6,
                                y: isExpanded ? 10 : 0)
                        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: shapeWidth)
                        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: shapeHeight)
                        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: isExpanded)

                    // Icons — only rendered when present and not expanded
                    if hasIcons && !isExpanded {
                        iconsView
                            .frame(height: extPillHeight)
                    }

                    // Expanded: edit + settings bar at top
                    if isExpanded {
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)

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

                            Spacer(minLength: 0)

                            Button("settings") {
                                ConnectionWindowController.shared.open()
                                NotificationCenter.default.post(name: .notchCollapseDropdown, object: nil)
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                            .contentShape(Capsule())

                            Spacer(minLength: 0)
                        }
                        .frame(width: shapeWidth, height: extPillHeight)
                        .opacity(contentVisible ? 1 : 0)
                    }

                    // Expanded: dropdown content below the bar
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
                                        }.onChange(of: proxy.size.height) { h in
                                            expandedContentHeight = h
                                        }
                                    }
                                )
                        }
                        .frame(width: shapeWidth)
                        .clipped()
                    }
                }
                .frame(width: shapeWidth, height: shapeHeight, alignment: .top)
                .allowsHitTesting(isExpanded)
                .transition(
                    .asymmetric(
                        insertion: .scale(scale: 0.4).combined(with: .opacity)
                            .animation(.spring(response: 0.38, dampingFraction: 0.75)),
                        removal: .scale(scale: 0.4).combined(with: .opacity)
                            .animation(.spring(response: 0.7, dampingFraction: 0.88))
                    )
                )
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, isExpanded ? 8 : (externalPanelHeight - extPillHeight) / 2)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .notchExpandDropdown)) { _ in
            openExpanded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .notchCollapseDropdown)) { _ in
            closeExpanded()
        }
        .onChange(of: hasIcons) { nowHasIcons in
            guard !isExpanded else { return }
            if nowHasIcons {
                pillCollapseTimer?.invalidate()
                pillCollapseTimer = nil
                withAnimation { pillVisible = true }
            } else {
                pillCollapseTimer?.invalidate()
                pillCollapseTimer = Timer.scheduledTimer(
                    withTimeInterval: iconExitDuration, repeats: false
                ) { _ in
                    DispatchQueue.main.async {
                        Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { _ in
                            DispatchQueue.main.async {
                                withAnimation(.easeOut(duration: 0.3)) {
                                    pillVisible = false
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            pillVisible = hasIcons
        }
    }

    // MARK: - Expand / Collapse

    private func openExpanded() {
        guard !isExpanded else { return }
        pillVisible = true
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
            isExpanded = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            withAnimation(.easeOut(duration: 0.2)) { contentVisible = true }
        }
    }

    private func closeExpanded() {
        guard isExpanded else { return }
        isEditMode = false
        withAnimation(.easeInOut(duration: 0.18)) { contentVisible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.spring(response: 0.48, dampingFraction: 0.88)) { isExpanded = false }
        }
    }

    // MARK: - Icons layout

    @ViewBuilder
    private var iconsView: some View {
        HStack(spacing: iconGap) {
            ForEach(Array(leftProviders.enumerated()), id: \.element) { idx, provider in
                iconView(provider: provider, outerIdx: idx)
            }
            ForEach(Array(rightProviders.enumerated()), id: \.element) { idx, provider in
                let outerIdx = rightProviders.count - 1 - idx
                iconView(provider: provider, outerIdx: outerIdx)
            }
        }
        .padding(.horizontal, sidePadding)
    }

    @ViewBuilder
    private func iconView(provider: LLMProvider, outerIdx: Int) -> some View {
        if let usage = registry.usageMap[provider] {
            WingIconView(usage: usage)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: provider.notchWing == .left ? .trailing : .leading)
                            .combined(with: .opacity)
                            .animation(.spring(response: 0.38, dampingFraction: 0.78)
                                .delay(Double(outerIdx) * staggerStep)),
                        removal: .move(edge: provider.notchWing == .left ? .trailing : .leading)
                            .combined(with: .opacity)
                            .animation(.spring(response: 0.45, dampingFraction: 0.85)
                                .delay(Double(outerIdx) * staggerStep))
                    )
                )
        }
    }
}
