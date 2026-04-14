import SwiftUI
import AppKit

/// Black pill that extends from the notch, flush to the top of the screen.
/// Flat top (connects to screen edge / notch), rounded bottom corners.
struct WingView: View {
    @Binding var isHovered: Bool
    let onTap: () -> Void
    @EnvironmentObject var registry: ProviderRegistry

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Full-width black top strip — makes pill visually connect to screen edge
            Color.black
                .frame(height: 4)
                .frame(maxWidth: .infinity)

            // The pill body with icons inside
            pillContent
                .offset(y: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var pillContent: some View {
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
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .background(
            WingPillShape(cornerRadius: 10)
                .fill(Color.black)
        )
        .shadow(
            color: isHovered ? .black.opacity(0.7) : .black.opacity(0.4),
            radius: isHovered ? 14 : 8,
            y: isHovered ? 8 : 4
        )
        .scaleEffect(isHovered ? 1.06 : 1.0, anchor: .top)
        .contentShape(WingPillShape(cornerRadius: 10))
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

/// Flat top, rounded bottom corners — attaches flush to screen edge
struct WingPillShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height - cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.width - cornerRadius, y: rect.height),
            control: CGPoint(x: rect.width, y: rect.height)
        )
        path.addLine(to: CGPoint(x: cornerRadius, y: rect.height))
        path.addQuadCurve(
            to: CGPoint(x: 0, y: rect.height - cornerRadius),
            control: CGPoint(x: 0, y: rect.height)
        )
        path.closeSubpath()
        return path
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
