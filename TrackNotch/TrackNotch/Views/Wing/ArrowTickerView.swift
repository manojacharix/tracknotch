import SwiftUI

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
