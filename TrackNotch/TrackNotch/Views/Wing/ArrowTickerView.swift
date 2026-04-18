import SwiftUI

// MARK: - Usage arc (used in dropdown rows as a mini progress indicator)

/// Partial arc — shared between the dropdown and any future wing views.
struct UsageArc: View {
    let percentage: Double
    let color: Color

    private var trimFraction: Double {
        let clamped = max(0.0, min(percentage, 100.0))
        if clamped < 1 { return 0.04 }
        return clamped / 100.0
    }

    var body: some View {
        Circle()
            .trim(from: 0, to: trimFraction)
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(-60))
    }
}

// MARK: - Arrow ticker

/// Upward-rolling arrow ticker shown beside API token providers in the wing.
/// Animates continuously upward every 1 second while tokens are being consumed.
struct ArrowTickerView: View {
    let isConsuming: Bool

    @State private var tickOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            // Ghost arrow above (appears as current arrow rolls out)
            Image(systemName: "arrow.up")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Color(hex: "ff9b2f"))
                .frame(height: 10)

            // Main arrow
            Image(systemName: "arrow.up")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Color(hex: "ff9b2f"))
                .frame(height: 10)
        }
        .offset(y: tickOffset)
        .frame(width: 10, height: 10)
        .clipped()
        .onAppear { startAnimating() }
        .onChange(of: isConsuming) { consuming in
            if consuming { startAnimating() } else { stopAnimating() }
        }
    }

    private func startAnimating() {
        guard isConsuming else { return }
        tickOffset = 0
        withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
            tickOffset = -10
        }
    }

    private func stopAnimating() {
        withAnimation(.easeOut(duration: 0.2)) {
            tickOffset = 0
        }
    }
}
