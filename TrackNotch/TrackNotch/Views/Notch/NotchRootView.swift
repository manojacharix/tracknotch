import SwiftUI

/// Root SwiftUI view rendered inside NotchWindow.
/// Switches between hardware notch mode (wing only)
/// and software notch mode (drawn notch + wing).
struct NotchRootView: View {
    let mode: NotchMode

    @EnvironmentObject var registry: ProviderRegistry
    @State private var isExpanded = false
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch mode {
            case .hardwareNotch:
                // Wing anchored to leading (left) edge — sits right beside the notch
                HStack {
                    WingView(isExpanded: $isExpanded, isHovered: $isHovered)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            case .softwareNotch:
                HStack(spacing: 0) {
                    SoftwareNotchShape()
                        .fill(Color.black)
                        .frame(width: 126, height: 37)

                    WingView(isExpanded: $isExpanded, isHovered: $isHovered)
                    Spacer()
                }
            }

            // Dropdown panel slides down on expand
            if isExpanded {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 37)
                    DropdownPanelView()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The curved notch shape drawn in software on non-notch displays
struct SoftwareNotchShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cornerRadius: CGFloat = 10

        // Draw notch shape — rounded bottom corners, flat top (sits at screen edge)
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
