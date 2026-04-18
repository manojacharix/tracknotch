import SwiftUI

private let iconSize: CGFloat         = 22   // WingIconView frame
private let iconGap: CGFloat          = 8    // gap between icons
private let outerSidePadding: CGFloat = 12   // pill outer-edge padding
private let innerSidePadding: CGFloat = 10   // notch-edge padding

struct NotchRootView: View {
    let mode: NotchMode
    let onToggleDropdown: () -> Void

    @EnvironmentObject var registry: ProviderRegistry
    @State private var geo: NotchGeometry? = nil

    // LEFT wing: Cursor, OpenAI API, Codex
    private var leftProviders:  [LLMProvider] { registry.activeProviders.filter { $0.notchWing == .left } }
    // RIGHT wing: Claude Code, Anthropic API, ChatGPT, Google
    private var rightProviders: [LLMProvider] { registry.activeProviders.filter { $0.notchWing == .right } }

    // Wing width = exactly enough for n icons with accurate edge paddings, 0 when empty
    private func wingWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * iconSize + CGFloat(count - 1) * iconGap + outerSidePadding + innerSidePadding
    }

    private var leftWingWidth:  CGFloat { wingWidth(count: leftProviders.count) }
    private var rightWingWidth: CGFloat { wingWidth(count: rightProviders.count) }
    private var pillHeight: CGFloat { geo?.notchHeight ?? 39 }

    private var pillWidth: CGFloat {
        guard let geo else { return 0 }
        return leftWingWidth + geo.notchWidth + rightWingWidth
    }

    // Offset within the full window so pill stays centered on the hardware notch
    private var pillLeadingOffset: CGFloat {
        guard let geo else { return 0 }
        return geo.leftWingWidth - leftWingWidth
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Full window anchor — must not intercept clicks below the pill
            Color.clear
                .frame(width: geo.map { $0.leftWingWidth + $0.notchWidth + $0.rightWingWidth } ?? 580,
                       height: trackNotchWindowHeight)
                .allowsHitTesting(false)

            if let geo {
                pillView(geo: geo)
            }
        }
        .onAppear {
            Task { @MainActor in
                geo = notchGeometry()
            }
        }
    }

    // MARK: - Pill

    @ViewBuilder
    private func pillView(geo: NotchGeometry) -> some View {
        // Pill and icons both top-aligned to the top of the screen.
        // Icons are vertically centered within the pill height.
        ZStack(alignment: .top) {
            // Black pill background — sits at top, exact notch height
            NotchShape(topCornerRadius: 6, bottomCornerRadius: 14)
                .fill(Color.black)
                .frame(width: pillWidth, height: pillHeight)
                .shadow(color: .black.opacity(0.5), radius: 8)

            // Icons — vertically centered inside the pill's height
            wingContent(geo: geo)
                .frame(width: pillWidth, height: pillHeight)
        }
        .frame(width: pillWidth, height: pillHeight)
        .offset(x: pillLeadingOffset)
        // Pill resizes to follow icons with a slightly slower spring so it trails behind them
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: leftProviders.count)
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: rightProviders.count)
    }

    // MARK: - Wing content

    /// Stagger delay: outermost icon animates first, inward toward the notch.
    /// Left wing: index 0 is outermost (leftmost) — delay increases right→notch.
    /// Right wing: index 0 is innermost (closest to notch) — delay increases left→notch,
    ///             so we reverse: last icon (outermost) gets delay 0.
    private let staggerStep: Double = 0.06

    @ViewBuilder
    private func wingContent(geo: NotchGeometry) -> some View {
        HStack(spacing: 0) {
            // LEFT wing — icons trailing-aligned, outermost = index 0
            if !leftProviders.isEmpty {
                HStack(spacing: iconGap) {
                    Spacer(minLength: 0)
                    ForEach(Array(leftProviders.enumerated()), id: \.element) { idx, provider in
                        if let usage = registry.usageMap[provider] {
                            WingIconView(usage: usage)
                                .transition(
                                    .asymmetric(
                                        insertion: .move(edge: .leading).combined(with: .opacity)
                                            .animation(.spring(response: 0.38, dampingFraction: 0.78)
                                                .delay(Double(idx) * staggerStep)),
                                        removal: .move(edge: .leading).combined(with: .opacity)
                                            .animation(.spring(response: 0.3, dampingFraction: 0.8)
                                                .delay(Double(idx) * staggerStep))
                                    )
                                )
                        }
                    }
                }
                .padding(.leading, outerSidePadding)
                .padding(.trailing, innerSidePadding)
                .frame(width: leftWingWidth, height: pillHeight, alignment: .center)
            }

            // Hardware notch gap
            Color.clear
                .frame(width: geo.notchWidth, height: pillHeight)

            // RIGHT wing — icons leading-aligned, outermost = last index
            if !rightProviders.isEmpty {
                HStack(spacing: iconGap) {
                    ForEach(Array(rightProviders.enumerated()), id: \.element) { idx, provider in
                        if let usage = registry.usageMap[provider] {
                            let outerIdx = rightProviders.count - 1 - idx  // 0 = outermost
                            WingIconView(usage: usage)
                                .transition(
                                    .asymmetric(
                                        insertion: .move(edge: .trailing).combined(with: .opacity)
                                            .animation(.spring(response: 0.38, dampingFraction: 0.78)
                                                .delay(Double(outerIdx) * staggerStep)),
                                        removal: .move(edge: .trailing).combined(with: .opacity)
                                            .animation(.spring(response: 0.3, dampingFraction: 0.8)
                                                .delay(Double(outerIdx) * staggerStep))
                                    )
                                )
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, innerSidePadding)
                .padding(.trailing, outerSidePadding)
                .frame(width: rightWingWidth, height: pillHeight, alignment: .center)
            }
        }
    }
}

// MARK: - Preview

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
