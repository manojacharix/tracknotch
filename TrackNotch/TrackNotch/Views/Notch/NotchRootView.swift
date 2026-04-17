import SwiftUI

private let iconSize: CGFloat   = 22   // WingIconView outer frame (tighter to avoid clipping)
private let iconGap: CGFloat    = 10   // gap between icons (per Figma)
private let outerSidePadding: CGFloat = 16 // pill outer-edge padding (clears bottom corner curve)
private let innerSidePadding: CGFloat = 10 // notch-edge padding (per Figma)

struct NotchRootView: View {
    let mode: NotchMode
    let onToggleDropdown: () -> Void

    @EnvironmentObject var registry: ProviderRegistry
    @State private var geo: NotchGeometry? = nil
    @State private var showGlow = false

    // LEFT wing: Cursor, OpenAI API, Codex
    private var leftProviders:  [LLMProvider] { registry.activeProviders.filter { $0.notchWing == .left } }
    // RIGHT wing: Claude Code, Anthropic API, ChatGPT, Google
    private var rightProviders: [LLMProvider] { registry.activeProviders.filter { $0.notchWing == .right } }
    private var hasActivity: Bool { !registry.activeProviders.isEmpty }

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
            // Full window anchor
            Color.clear
                .frame(width: geo.map { $0.leftWingWidth + $0.notchWidth + $0.rightWingWidth } ?? 580,
                       height: trackNotchWindowHeight)

            if let geo {
                pillView(geo: geo)
            }
        }
        .onAppear {
            Task { @MainActor in
                geo = notchGeometry()
                showGlow = true
                try? await Task.sleep(for: .seconds(3))
                withAnimation(.easeOut(duration: 0.4)) { showGlow = false }
            }
        }
        .onChange(of: registry.usageMap) { _ in
            withAnimation(.easeIn(duration: 0.2)) { showGlow = hasActivity }
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
                .overlay {
                    if showGlow {
                        NotchGlowBorder(
                            topCornerRadius: 6,
                            bottomCornerRadius: 14,
                            glowColor:   Color(red: 0.9, green: 0.4, blue: 0.1),
                            brightColor: Color(red: 1.0, green: 0.55, blue: 0.2)
                        )
                    }
                }
                .shadow(color: .black.opacity(0.5), radius: 8)

            // Icons — vertically centered inside the pill's height
            wingContent(geo: geo)
                .frame(width: pillWidth, height: pillHeight)
        }
        .frame(width: pillWidth, height: pillHeight)
        .offset(x: pillLeadingOffset)
        .contentShape(Rectangle())
        .onTapGesture { onToggleDropdown() }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: leftProviders.count)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: rightProviders.count)
    }

    // MARK: - Wing content

    @ViewBuilder
    private func wingContent(geo: NotchGeometry) -> some View {
        HStack(spacing: 0) {
            // LEFT wing — icons trailing-aligned, vertically centered
            if !leftProviders.isEmpty {
                HStack(spacing: iconGap) {
                    Spacer(minLength: 0)
                    ForEach(leftProviders, id: \.self) { provider in
                        if let usage = registry.usageMap[provider] {
                            WingIconView(usage: usage)
                                .transition(.scale.combined(with: .opacity))
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

            // RIGHT wing — icons leading-aligned, vertically centered
            if !rightProviders.isEmpty {
                HStack(spacing: iconGap) {
                    ForEach(rightProviders, id: \.self) { provider in
                        if let usage = registry.usageMap[provider] {
                            WingIconView(usage: usage)
                                .transition(.scale.combined(with: .opacity))
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
