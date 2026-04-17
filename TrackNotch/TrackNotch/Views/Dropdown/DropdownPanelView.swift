import SwiftUI

/// Dropdown panel that slides down from the notch on click.
/// Matches Figma `clicked.png`: compact rows with cost/% → bar → icon.
struct DropdownPanelView: View {
    var onDismiss: (() -> Void)? = nil
    @EnvironmentObject var registry: ProviderRegistry
    @State private var isEditMode = false
    @State private var providerOrder: [LLMProvider] = []

    private var visibleProviders: [LLMProvider] {
        providerOrder.filter { registry.usageMap[$0] != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header: edit / settings
            HStack {
                Button(isEditMode ? "done" : "edit") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isEditMode { registry.saveProviderOrder(providerOrder) }
                        isEditMode.toggle()
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundColor(.white.opacity(0.45))

                Spacer()

                Button("settings") {
                    ConnectionWindowController.shared.open()
                    onDismiss?()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundColor(.white.opacity(0.45))
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if visibleProviders.isEmpty {
                // Empty state
                VStack(spacing: 10) {
                    Image(systemName: "plus.circle.dashed")
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.2))
                    Text("No providers connected")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.4))
                    Button {
                        ConnectionWindowController.shared.open()
                        onDismiss?()
                    } label: {
                        Text("Add connectors")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.1)))
                    }
                    .buttonStyle(.borderless)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else if isEditMode {
                EditableProviderList(providers: $providerOrder, registry: registry)
            } else {
                // Provider rows
                VStack(spacing: 0) {
                    ForEach(visibleProviders, id: \.self) { provider in
                        if let usage = registry.usageMap[provider] {
                            DropdownProviderRow(usage: usage)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.bottom, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(hex: "1a1b1c"))
        )
        .frame(width: 200)
        .shadow(color: .black.opacity(0.6), radius: 16, y: 6)
        .onAppear {
            providerOrder = registry.orderedProviders
        }
    }
}

// MARK: - Provider Row (Figma: cost → bar → % + icon)

struct DropdownProviderRow: View {
    let usage: ProviderUsage
    @State private var animatedPct: Double = 0

    var body: some View {
        HStack(spacing: 6) {
            // Cost or value label
            Text(displayValue)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.85))
                .monospacedDigit()
                .frame(width: 36, alignment: .leading)

            // Small provider icon with indicator
            Image(usage.provider.iconName)
                .resizable()
                .scaledToFit()
                .frame(width: 10, height: 10)

            // Usage bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.08))

                    RoundedRectangle(cornerRadius: 4)
                        .fill(barGradient)
                        .frame(width: max(2, geo.size.width * CGFloat(animatedPct / 100)))
                        .animation(.easeOut(duration: 0.6), value: animatedPct)
                }
            }
            .frame(height: 16)

            // Percentage label
            Text(pctLabel)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundColor(.white.opacity(0.6))
                .monospacedDigit()
                .frame(width: 28, alignment: .trailing)

            // Wing icon: arc for subscription, arrow for API
            if usage.billingType == .apiToken {
                ArrowTickerView(isConsuming: usage.isActivelyConsuming)
                    .frame(width: 8, height: 8)
            } else {
                // Mini arc indicator
                UsageArc(percentage: usage.percentage, color: barColor)
                    .frame(width: 10, height: 10)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) { animatedPct = usage.percentage }
        }
        .onChange(of: usage.percentage) { newValue in
            withAnimation(.easeOut(duration: 0.5)) { animatedPct = newValue }
        }
    }

    private var displayValue: String {
        switch usage.billingType {
        case .apiToken:
            if let cost = usage.costUsedUSD {
                return String(format: "$%.1f", cost)
            }
            return "$—"
        case .subscription:
            return "\(Int(usage.percentage))%"
        case .localUsage:
            return usage.formattedTokens ?? "—"
        }
    }

    private var pctLabel: String {
        "\(Int(usage.percentage))%"
    }

    private var barGradient: LinearGradient {
        LinearGradient(
            colors: [barColor.opacity(0.7), barColor],
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
