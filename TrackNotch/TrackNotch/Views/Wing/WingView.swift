import SwiftUI

/// The wing area showing active provider icons beside the notch.
/// Only visible when at least one provider is actively being used.
struct WingView: View {
    @Binding var isExpanded: Bool
    @Binding var isHovered: Bool
    @EnvironmentObject var registry: ProviderRegistry

    var body: some View {
        HStack(spacing: 6) {
            ForEach(registry.activeProviders, id: \.self) { provider in
                if let usage = registry.usageMap[provider] {
                    ProviderIconView(usage: usage)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 37)
        .scaleEffect(isHovered ? 1.05 : 1.0)
        .shadow(color: isHovered ? .black.opacity(0.4) : .clear, radius: 8, y: 4)
        .onTapGesture {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                isExpanded.toggle()
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: registry.activeProviders)
    }
}
