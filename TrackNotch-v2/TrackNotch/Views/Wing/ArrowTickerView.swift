import SwiftUI

// MARK: - API spend indicator

/// Small upward-drifting arrow shown beside API token providers in the wing.
/// When consuming: arrow drifts up and fades out, snaps back, repeats.
/// When idle: static arrow at full opacity.
struct ArrowTickerView: View {
    let isConsuming: Bool

    @State private var offsetY: CGFloat = 0
    @State private var opacity: Double = 0.7
    @State private var looping = false

    var body: some View {
        Image(systemName: "arrow.up")
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(Color(hex: "ff9b2f"))
            .opacity(opacity)
            .offset(y: offsetY)
            .onAppear {
                if isConsuming { startLoop() }
            }
            .onChange(of: isConsuming) { consuming in
                if consuming { startLoop() } else { stopLoop() }
            }
    }

    private func startLoop() {
        guard !looping else { return }
        looping = true
        runCycle()
    }

    private func runCycle() {
        guard looping else { return }
        // Reset to start position instantly (no animation)
        offsetY = 0
        opacity = 0.9
        // Drift up and fade over 0.8s
        withAnimation(.easeIn(duration: 0.8)) {
            offsetY = -9
            opacity = 0.0
        }
        // After cycle completes, repeat
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            runCycle()
        }
    }

    private func stopLoop() {
        looping = false
        withAnimation(.easeOut(duration: 0.25)) {
            offsetY = 0
            opacity = 0.7
        }
    }
}
