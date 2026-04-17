import SwiftUI

// MARK: - Wing icon dispatcher

/// Shows the correct icon style based on which wing the provider belongs to.
/// Only rendered when the provider is actively connected/in use.
struct WingIconView: View {
    let usage: ProviderUsage

    var body: some View {
        if usage.provider.defaultBillingType == .apiToken {
            APITokenIconView(usage: usage)
        } else {
            LeftWingIconView(usage: usage)
        }
    }
}

// MARK: - Left wing: icon + arc (Claude Code, Codex, Cursor, ChatGPT Desktop)

struct LeftWingIconView: View {
    let usage: ProviderUsage
    @State private var animatedPct: Double = 0
    @State private var pulsing = false

    private var isDepleted: Bool { usage.percentage >= 100 }

    var body: some View {
        ZStack {
            // Provider icon — full-color, no tint override
            Image(usage.provider.iconName)
                .resizable()
                .scaledToFit()
                .frame(width: 11, height: 11)

            // Usage arc wraps AROUND icon; gap sits at top (~12 o'clock).
            UsageArc(percentage: animatedPct, color: arcColor)
                .frame(width: 18, height: 18)
                .opacity(isDepleted && pulsing ? 0.3 : 1.0)
        }
        .frame(width: 22, height: 22)
        .onAppear {
            withAnimation(.easeOut(duration: 1.0)) { animatedPct = usage.percentage }
            if isDepleted { startPulse() }
        }
        .onChange(of: usage.percentage) { newVal in
            withAnimation(.easeOut(duration: 0.5)) { animatedPct = newVal }
            if newVal >= 100 { startPulse() } else { pulsing = false }
        }
    }

    private var arcColor: Color {
        if isDepleted { return Color(hex: "fb4141") }
        switch usage.percentage {
        case 0..<20:  return Color(hex: "b4e50d")
        case 20..<75: return Color(hex: "ff9b2f")
        default:      return Color(hex: "fb4141")
        }
    }

    private func startPulse() {
        guard isDepleted else { return }
        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
            pulsing = true
        }
    }
}



// MARK: - Usage arc shape

/// Partial arc with gap centered at the top (~12 o'clock).
/// Arc starts at ~1 o'clock and sweeps clockwise; length grows with usage %.
/// At 0% → nub at 1 o'clock. At 100% → full 360° (gap closes).
struct UsageArc: View {
    let percentage: Double
    let color: Color

    /// Fraction of the circle the arc covers (0…1).
    private var trimFraction: Double {
        let clamped = max(0.0, min(percentage, 100.0))
        if clamped < 1 { return 0.04 }           // small visible nub at very low %
        return clamped / 100.0                    // linear map 0→1
    }

    var body: some View {
        // Circle().trim starts at 3 o'clock (0°) going clockwise in SwiftUI.
        // We want the arc to START at ~1 o'clock (-60° from horizontal = 300° / or -60°)
        // and sweep clockwise, leaving the gap centered at top (12 o'clock).
        //
        // Rotating by -120° moves the "start" point from 3 o'clock counter-clockwise
        // to ~11 o'clock — i.e. the arc begins just past the top-left and sweeps
        // clockwise through 12→1→3→…, so at low % only upper-right shows (per Figma).
        //
        // Wait: Figma shows arc BEGINNING at top-right going clockwise. The start
        // of the visible stroke sits at ~1 o'clock. Rotating trim(from:0,to:f) by
        // -60° places the start at ~1 o'clock. Gap therefore centers at ~12 o'clock
        // when fraction < 1, which matches Figma.
        Circle()
            .trim(from: 0, to: trimFraction)
            .stroke(color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
            .rotationEffect(.degrees(-60))
            // No shadow — keeps arc clean and prevents clipping at pill edges
    }
}

// MARK: - API Token arrow (for API-key providers when consuming)

/// Bare icon + upward rolling orange arrow, shown for API providers actively consuming.
struct APITokenIconView: View {
    let usage: ProviderUsage

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(usage.provider.iconName)
                .resizable()
                .scaledToFit()
                .frame(width: 12, height: 12)
                .padding(.bottom, 3)
                .padding(.leading, 3)

            ArrowTickerView(isConsuming: usage.isActivelyConsuming)
                .frame(width: 9, height: 9)
        }
        .frame(width: 22, height: 22)
    }
}

// Keep for backward compatibility
typealias SubscriptionIconView = LeftWingIconView
