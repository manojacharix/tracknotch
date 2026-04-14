import SwiftUI
import PhosphorSwift

/// A provider row in drag-reorder edit mode.
/// Shows a Phosphor DotsSixVertical drag handle on the left.
struct EditModeRow: View {
    let usage: ProviderUsage

    var body: some View {
        HStack(spacing: 10) {
            // Drag handle — Phosphor DotsSixVertical
            Ph.dotsSixVertical.bold
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
                .foregroundColor(.white.opacity(0.35))

            Image(usage.provider.iconName)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)

            Text(usage.provider.displayName)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundColor(.white.opacity(0.7))

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}
