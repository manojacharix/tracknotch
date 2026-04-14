import SwiftUI
import AppKit

/// The wing area showing active provider icons beside the notch.
/// Always visible on the right wing — shows a pulsing + when no providers connected.
struct WingView: View {
    @Binding var isExpanded: Bool
    @Binding var isHovered: Bool
    @EnvironmentObject var registry: ProviderRegistry

    var body: some View {
        HStack(spacing: 6) {
            if registry.activeProviders.isEmpty {
                PulsingAddButton()
                    .transition(.scale.combined(with: .opacity))
            } else {
                ForEach(registry.activeProviders, id: \.self) { provider in
                    if let usage = registry.usageMap[provider] {
                        ProviderIconView(usage: usage)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 37, minHeight: 37)
        .contentShape(Rectangle())
        .scaleEffect(isHovered ? 1.08 : 1.0)
        .shadow(color: isHovered ? .black.opacity(0.5) : .clear, radius: 10, y: 5)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.65)) {
                isHovered = hovering
            }
            if hovering {
                NSHapticFeedbackManager.defaultPerformer.perform(
                    .alignment, performanceTime: .default
                )
            }
        }
        .onTapGesture {
            NSHapticFeedbackManager.defaultPerformer.perform(
                .levelChange, performanceTime: .default
            )
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                isExpanded.toggle()
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: registry.activeProviders)
    }
}

// MARK: - Pulsing + button (new user onboarding hint)

/// A subtle + icon that gently pulses in opacity every 3 seconds
/// to draw new users toward the notch.
private struct PulsingAddButton: View {
    @State private var isPulsing = false

    var body: some View {
        Image(systemName: "plus.circle")
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(.white.opacity(isPulsing ? 0.85 : 0.35))
            .onAppear { startPulse() }
    }

    private func startPulse() {
        // Delay first pulse by 1s so it doesn't fire immediately on launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            pulse()
        }
    }

    private func pulse() {
        withAnimation(.easeInOut(duration: 0.6)) {
            isPulsing = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            withAnimation(.easeInOut(duration: 0.6)) {
                isPulsing = false
            }
        }
        // Repeat every 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            pulse()
        }
    }
}
