import SwiftUI

// MARK: - External Monitor overlay
//
// Behaviour:
//   Idle    → small dot, very low opacity
//   Active  → dot expands, icons fan out from center symmetrically
//   Collapse→ icons sequence inward, pill shrinks back to dot, dot fades

private let dotSize:      CGFloat = 6
private let dotIdleOpacity: Double = 0.25
private let iconSize:     CGFloat = 22
private let iconGap:      CGFloat = 8
private let sidePadding:  CGFloat = 10
private let pillHeight:   CGFloat = 32
private let cornerRadius: CGFloat = 16
private let staggerStep:  Double  = 0.06

struct ExternalMonitorView: View {
    let onToggleDropdown: () -> Void

    @EnvironmentObject var registry: ProviderRegistry

    private var activeProviders: [LLMProvider] { registry.activeProviders }
    private var hasActivity:     Bool           { !activeProviders.isEmpty }

    // Split into left/right halves from center — left half reversed so outermost is index 0
    private var leftProviders:  [LLMProvider] {
        let half = activeProviders.count / 2
        return Array(activeProviders.prefix(half).reversed())
    }
    private var rightProviders: [LLMProvider] {
        let half = activeProviders.count / 2
        return Array(activeProviders.dropFirst(half))
    }

    // Pill width: enough for all icons centered with gap + padding on each side
    private var pillWidth: CGFloat {
        guard hasActivity else { return dotSize }
        let n = CGFloat(activeProviders.count)
        return n * iconSize + max(0, n - 1) * iconGap + sidePadding * 2
    }

    var body: some View {
        ZStack {
            // Invisible full-width anchor — click-through
            Color.clear
                .frame(width: externalPanelWidth, height: externalPanelHeight)
                .allowsHitTesting(false)

            // Pill / dot
            ZStack {
                // Background
                RoundedRectangle(cornerRadius: hasActivity ? cornerRadius : dotSize / 2)
                    .fill(Color.black)
                    .frame(width: pillWidth, height: hasActivity ? pillHeight : dotSize)

                // Icons fan out from center
                if hasActivity {
                    iconsView
                }
            }
            .shadow(color: .black.opacity(0.4), radius: 6)
            .opacity(hasActivity ? 1 : dotIdleOpacity)
            .animation(.spring(response: 0.42, dampingFraction: 0.8), value: hasActivity)
            .animation(.spring(response: 0.42, dampingFraction: 0.8), value: activeProviders.count)
            .onTapGesture { onToggleDropdown() }
            // Position at top-center of the panel
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, (externalPanelHeight - pillHeight) / 2)
        }
    }

    // MARK: - Icons layout

    @ViewBuilder
    private var iconsView: some View {
        HStack(spacing: iconGap) {
            // Left half — outermost is index 0 (already reversed)
            ForEach(Array(leftProviders.enumerated()), id: \.element) { idx, provider in
                iconView(provider: provider, outerIdx: idx)
            }
            // Right half — outermost is last index
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
                        insertion: .scale(scale: 0.3).combined(with: .opacity)
                            .animation(.spring(response: 0.35, dampingFraction: 0.72)
                                .delay(Double(outerIdx) * staggerStep)),
                        removal: .scale(scale: 0.3).combined(with: .opacity)
                            .animation(.spring(response: 0.28, dampingFraction: 0.8)
                                .delay(Double(outerIdx) * staggerStep))
                    )
                )
        }
    }
}
