import SwiftUI
import AppKit

/// Provider icons rendered directly in the menu bar area beside the notch.
/// No background — icons sit bare on the menu bar, just like system status icons.
struct WingView: View {
    @Binding var isHovered: Bool
    let onTap: () -> Void
    @EnvironmentObject var registry: ProviderRegistry

    var body: some View {
        HStack(spacing: 8) {
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
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .scaleEffect(isHovered ? 1.08 : 1.0)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.65)) {
                isHovered = hovering
            }
            if hovering {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            }
        }
        .onTapGesture {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
            onTap()
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: registry.activeProviders)
        .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isHovered)
    }
}

// MARK: - Pulsing + button

struct PulsingAddButton: View {
    @State private var isPulsing = false

    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white.opacity(isPulsing ? 1.0 : 0.4))
            .frame(width: 20, height: 20)
            .onAppear { startPulse() }
    }

    private func startPulse() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { pulse() }
    }

    private func pulse() {
        withAnimation(.easeInOut(duration: 0.5)) { isPulsing = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.easeInOut(duration: 0.5)) { isPulsing = false }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { pulse() }
    }
}
