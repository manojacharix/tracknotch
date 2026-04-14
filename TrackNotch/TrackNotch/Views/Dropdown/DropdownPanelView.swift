import SwiftUI

/// Dropdown panel that slides down from the notch on click.
/// Shows per-provider usage bars with quota% (subscription) or $spend (API token).
struct DropdownPanelView: View {
    @EnvironmentObject var registry: ProviderRegistry
    @State private var isEditMode = false
    @State private var showSettings = false
    @State private var providerOrder: [LLMProvider] = []

    var body: some View {
        VStack(spacing: 0) {
            // Per-provider rows
            if isEditMode {
                EditableProviderList(providers: $providerOrder, registry: registry)
            } else {
                VStack(spacing: 2) {
                    ForEach(providerOrder, id: \.self) { provider in
                        if let usage = registry.usageMap[provider] {
                            DropdownProviderRow(usage: usage)
                        }
                    }
                }
            }

            Divider()
                .background(Color.white.opacity(0.1))

            // Footer
            HStack {
                Button("settings") { showSettings = true }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))

                Spacer()

                Button(isEditMode ? "done" : "edit") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isEditMode {
                            registry.saveProviderOrder(providerOrder)
                        }
                        isEditMode.toggle()
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundColor(.white.opacity(0.5))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(hex: "252728"))
        )
        .frame(width: 280)
        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
        .sheet(isPresented: $showSettings) {
            ProviderConnectionView()
        }
        .onAppear {
            providerOrder = registry.orderedProviders
        }
    }
}

// MARK: - Provider Row

struct DropdownProviderRow: View {
    let usage: ProviderUsage
    @State private var animatedPercentage: Double = 0

    var body: some View {
        HStack(spacing: 10) {
            Image(usage.provider.iconName)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(hex: "d9d9d9").opacity(0.15))

                    RoundedRectangle(cornerRadius: 3)
                        .fill(gradientFill)
                        .frame(width: geo.size.width * CGFloat(animatedPercentage / 100))
                        .animation(.easeOut(duration: 0.6), value: animatedPercentage)
                }
            }
            .frame(height: 6)

            // Subscription → quota %; API token → $spend + rolling arrow
            HStack(spacing: 3) {
                Text(displayValue)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundColor(.white.opacity(0.8))
                    .monospacedDigit()

                if usage.billingType == .apiToken {
                    ArrowTickerView(isConsuming: usage.isActivelyConsuming)
                }
            }
            .frame(width: 48, alignment: .trailing)

            // Reset time for subscription
            if usage.billingType == .subscription, usage.resetsIn != nil {
                Text(usage.formattedResetsIn)
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundColor(.white.opacity(0.35))
                    .frame(width: 40, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) {
                animatedPercentage = usage.percentage
            }
        }
        .onChange(of: usage.percentage) { newValue in
            withAnimation(.easeOut(duration: 0.5)) {
                animatedPercentage = newValue
            }
        }
    }

    private var displayValue: String {
        switch usage.billingType {
        case .apiToken:
            if let cost = usage.costUsedUSD {
                return String(format: "$%.2f", cost)
            }
            return "$—"
        case .subscription:
            return "\(Int(usage.percentage))%"
        }
    }

    private var gradientFill: LinearGradient {
        let color = barColor
        return LinearGradient(
            colors: [color.opacity(0.6), color],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var barColor: Color {
        switch usage.percentage {
        case 0..<20:  return Color(hex: "b4e50d")
        case 20..<75: return Color(hex: "ff9b2f")
        default:      return Color(hex: "fb4141")
        }
    }
}

// MARK: - Editable List (drag to reorder)

struct EditableProviderList: View {
    @Binding var providers: [LLMProvider]
    let registry: ProviderRegistry

    var body: some View {
        VStack(spacing: 2) {
            ForEach(providers, id: \.self) { provider in
                if let usage = registry.usageMap[provider] {
                    EditModeRow(usage: usage)
                }
            }
            .onMove { from, to in
                providers.move(fromOffsets: from, toOffset: to)
            }
        }
    }
}
