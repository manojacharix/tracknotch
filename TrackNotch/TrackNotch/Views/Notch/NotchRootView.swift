import SwiftUI

/// Root SwiftUI view rendered inside the slim 37pt NotchWindow.
/// All it does is show the wing icons and respond to hover/tap.
/// The dropdown is a separate DropdownWindow managed by NotchWindow.
struct NotchRootView: View {
    let mode: NotchMode
    let onToggleDropdown: () -> Void

    @EnvironmentObject var registry: ProviderRegistry
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            switch mode {
            case .hardwareNotch:
                WingView(isHovered: $isHovered, onTap: onToggleDropdown)
                Spacer()

            case .softwareNotch:
                SoftwareNotchShape()
                    .fill(Color.black)
                    .frame(width: 126, height: 37)
                WingView(isHovered: $isHovered, onTap: onToggleDropdown)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The curved notch shape drawn in software on non-notch displays
struct SoftwareNotchShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cornerRadius: CGFloat = 10
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
