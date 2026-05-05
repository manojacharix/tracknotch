import SwiftUI

// MARK: - Wing indicator: icon with usage arc (subscription) or animated arrow (API spend)

/// Shows the provider's icon with either:
/// - A colored arc (subscription/localUsage billing): indicates quota %.
/// - An animated upward arrow (apiToken billing): animates continuously while spending.
/// Background is transparent — black notch shows through.
struct WingIconView: View {
    let usage: ProviderUsage
    @State private var pulsing = false

    private var isAPISpend: Bool { usage.billingType == .apiToken }
    private var isDepleted: Bool { usage.percentage >= 100 }

    private var arcColor: Color {
        if isDepleted { return Color(hex: "fb4141") }
        switch usage.percentage {
        case 0..<20:  return Color(hex: "b4e50d")   // green
        case 20..<75: return Color(hex: "ff9b2f")   // orange
        default:      return Color(hex: "fb4141")   // red
        }
    }

    /// Trim fraction: 0→1 maps to 0→360°. Minimum sliver so something is visible even at ~0%.
    private var trimFraction: Double {
        let clamped = min(usage.percentage, 100.0)
        return clamped < 1 ? 0.03 : clamped / 100.0
    }

    var body: some View {
        ZStack {
            if isAPISpend {
                // API spend: animated arrow only — cost is shown in the
                // dropdown pill, no need for an arc on the wing icon.
                ArrowTickerView(isConsuming: usage.isActivelyConsuming)
                    .offset(x: 8, y: -8)
            } else {
                // Subscription/local: colored arc indicating quota %
                Circle()
                    .trim(from: 0, to: trimFraction)
                    .stroke(
                        arcColor.opacity(isDepleted && pulsing ? 0.35 : 1.0),
                        style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
                    )
                    .frame(width: 18, height: 18)
                    .rotationEffect(.degrees(-90))   // start at 12 o'clock
            }

            // Provider icon — rendered as template (declared in asset catalog)
            Image(usage.provider.iconName)
                .resizable()
                .scaledToFit()
                .foregroundColor(.white)
                .frame(width: 13, height: 13)
        }
        .frame(width: 22, height: 22)
        .onAppear {
            if !isAPISpend && isDepleted { startPulse() }
        }
        .onChange(of: usage.percentage) { newVal in
            if !isAPISpend {
                if newVal >= 100 { startPulse() } else { stopPulse() }
            }
        }
    }

    private func startPulse() {
        guard !pulsing else { return }   // already pulsing — don't stack animations
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            pulsing = true
        }
    }

    private func stopPulse() {
        guard pulsing else { return }
        withAnimation(.easeOut(duration: 0.3)) { pulsing = false }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 16) {
        Text("Subscription arc: 2% · 45% · 80% · 100%").font(.caption).foregroundColor(.gray)
        HStack(spacing: 16) {
            ForEach([2.0, 45.0, 80.0, 100.0], id: \.self) { pct in
                WingIconView(usage: ProviderUsage(
                    provider: .claudeCode, billingType: .subscription, window: .weekly,
                    percentage: pct, resetsAt: nil, tokensUsed: 50000, tokensLimit: 2500000,
                    costUsedUSD: nil, costLimitUSD: nil, modelBreakdown: [], fetchedAt: Date(),
                    isActivelyConsuming: true
                ))
            }
        }
        Divider().background(Color.gray)
        Text("API spend arrow (active · idle)").font(.caption).foregroundColor(.gray)
        HStack(spacing: 16) {
            WingIconView(usage: ProviderUsage(
                provider: .anthropicAPI, billingType: .apiToken, window: .monthly,
                percentage: 30, resetsAt: nil, tokensUsed: 10000, tokensLimit: nil,
                costUsedUSD: 1.20, costLimitUSD: 4.00, modelBreakdown: [], fetchedAt: Date(),
                isActivelyConsuming: true
            ))
            WingIconView(usage: ProviderUsage(
                provider: .anthropicAPI, billingType: .apiToken, window: .monthly,
                percentage: 30, resetsAt: nil, tokensUsed: 10000, tokensLimit: nil,
                costUsedUSD: 1.20, costLimitUSD: 4.00, modelBreakdown: [], fetchedAt: Date(),
                isActivelyConsuming: false
            ))
        }
    }
    .padding(20)
    .background(Color.black)
}
