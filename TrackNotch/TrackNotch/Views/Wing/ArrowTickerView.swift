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

// MARK: - API spend indicator

/// Small upward-drifting arrow shown beside API token providers in the wing.
/// When consuming: arrow floats up and fades out, then resets and repeats.
/// When idle: static arrow at rest position.
struct ArrowTickerView: View {
    let isConsuming: Bool

    @State private var offsetY: CGFloat = 0
    @State private var opacity: Double = 0.7
    @State private var animating = false

    var body: some View {
        Image(systemName: "arrow.up")
            .font(.system(size: 6, weight: .bold))
            .foregroundStyle(Color(hex: "ff9b2f").opacity(opacity))
            .offset(y: offsetY)
            .onAppear {
                if isConsuming { startDrift() }
            }
            .onChange(of: isConsuming) { consuming in
                if consuming { startDrift() } else { stopDrift() }
            }
    }

    private func startDrift() {
        guard !animating else { return }
        animating = true
        offsetY = 0
        opacity = 0.7
        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: false)) {
            offsetY = -5
            opacity = 0.0
        }
    }

    private func stopDrift() {
        animating = false
        withAnimation(.easeOut(duration: 0.3)) {
            offsetY = 0
            opacity = 0.7
        }
    }
}
