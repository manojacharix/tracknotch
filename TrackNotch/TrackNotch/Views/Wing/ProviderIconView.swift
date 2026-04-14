import SwiftUI

/// Routes to the correct icon view based on billing type.
struct ProviderIconView: View {
    let usage: ProviderUsage

    var body: some View {
        switch usage.billingType {
        case .subscription:
            SubscriptionIconView(usage: usage)
        case .apiToken:
            APITokenIconView(usage: usage)
        }
    }
}

// MARK: - Subscription: circle + ring

/// Ellipse circle background + provider icon + colored usage ring.
struct SubscriptionIconView: View {
    let usage: ProviderUsage

    @State private var animatedPercentage: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(hex: "252728"))
                .frame(width: 26, height: 26)

            Circle()
                .trim(from: 0, to: animatedPercentage / 100)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 22, height: 22)

            Image(usage.provider.iconName)
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
        }
        .frame(width: 26, height: 26)
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) {
                animatedPercentage = usage.percentage
            }
        }
        .onChange(of: usage.percentage) { newValue in
            withAnimation(.easeOut(duration: 0.5)) {
                animatedPercentage = newValue
            }
        }
        .modifier(PulseModifier(active: usage.percentage >= 100))
    }

    private var ringColor: Color {
        switch usage.percentage {
        case 0..<20:  return Color(hex: "b4e50d")
        case 20..<75: return Color(hex: "ff9b2f")
        default:      return Color(hex: "fb4141")
        }
    }
}

// MARK: - API Token: icon only + rolling arrow

/// Provider icon (no circle) + upward rolling ArrowTickerView beside it.
struct APITokenIconView: View {
    let usage: ProviderUsage

    var body: some View {
        HStack(spacing: 3) {
            Image(usage.provider.iconName)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)

            ArrowTickerView(isConsuming: usage.isActivelyConsuming)
        }
        .frame(height: 26)
    }
}

// MARK: - Pulse at limit

struct PulseModifier: ViewModifier {
    let active: Bool
    @State private var pulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(pulsing ? 1.15 : 1.0)
            .onAppear {
                guard active else { return }
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
            .onChange(of: active) { isActive in
                if isActive {
                    withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                        pulsing = true
                    }
                } else {
                    pulsing = false
                }
            }
    }
}
