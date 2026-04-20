import SwiftUI
import PhosphorSwift
import UniformTypeIdentifiers

/// Content rendered inside the expanded notch shape.
/// No background or shadow — those are owned by NotchRootView's NotchShape.
struct DropdownContent: View {
    var onDismiss: (() -> Void)? = nil
    @Binding var isEditMode: Bool
    @EnvironmentObject var registry: ProviderRegistry
    @State private var providerOrder: [LLMProvider] = []
    @State private var draggingProvider: LLMProvider? = nil
    @State private var dropTargetProvider: LLMProvider? = nil

    private var visibleProviders: [LLMProvider] {
        providerOrder.filter { registry.usageMap[$0] != nil }
    }

    private let columns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]

    var body: some View {
        VStack(spacing: 0) {
            if visibleProviders.isEmpty {
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

            } else {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(visibleProviders, id: \.self) { provider in
                        if let usage = registry.usageMap[provider] {
                            pillCell(provider: provider, usage: usage)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 2)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: isEditMode)
        .onAppear { syncProviderOrder() }
        .onChange(of: registry.usageMap.count) { _ in syncProviderOrder() }
        .onChange(of: isEditMode) { editing in
            if !editing { registry.saveProviderOrder(providerOrder) }
        }
    }

    @ViewBuilder
    private func pillCell(provider: LLMProvider, usage: ProviderUsage) -> some View {
        HStack(spacing: 4) {
            if isEditMode {
                Ph.dotsSixVertical.bold
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12, height: 12)
                    .foregroundColor(.white.opacity(0.3))
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            DropdownProviderPill(usage: usage, isEditMode: isEditMode)
        }
        .opacity(draggingProvider == provider ? 0.4 : 1)
        .overlay(
            dropTargetProvider == provider && draggingProvider != provider
                ? RoundedRectangle(cornerRadius: 26)
                    .stroke(Color.white.opacity(0.3), lineWidth: 1.5)
                : nil
        )
        .onDrag {
            draggingProvider = provider
            return NSItemProvider(object: provider.rawValue as NSString)
        }
        .onDrop(of: [UTType.text], delegate: ProviderDropDelegate(
            target: provider,
            providers: $providerOrder,
            dragging: $draggingProvider,
            dropTarget: $dropTargetProvider
        ))
    }

    private func syncProviderOrder() {
        let current = registry.orderedProviders
        // Add any new providers not in local order
        let missing = current.filter { !providerOrder.contains($0) }
        if !missing.isEmpty {
            providerOrder.append(contentsOf: missing)
        }
        // If local order is empty, just take the registry order
        if providerOrder.isEmpty {
            providerOrder = current
        }
    }
}

// MARK: - Drop delegate for grid reorder

private struct ProviderDropDelegate: DropDelegate {
    let target: LLMProvider
    @Binding var providers: [LLMProvider]
    @Binding var dragging: LLMProvider?
    @Binding var dropTarget: LLMProvider?

    func dropEntered(info: DropInfo) { dropTarget = target }
    func dropExited(info: DropInfo)  { if dropTarget == target { dropTarget = nil } }

    func performDrop(info: DropInfo) -> Bool {
        defer { dragging = nil; dropTarget = nil }
        guard let from = dragging,
              let fromIdx = providers.firstIndex(of: from),
              let toIdx   = providers.firstIndex(of: target),
              fromIdx != toIdx
        else { return false }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            providers.move(fromOffsets: IndexSet(integer: fromIdx), toOffset: toIdx > fromIdx ? toIdx + 1 : toIdx)
        }
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

// MARK: - Half-size provider pill

struct DropdownProviderPill: View {
    let usage: ProviderUsage
    var isEditMode: Bool = false
    @State private var animatedPct: Double?
    @State private var hasAnimatedIn: Bool = false

    private let pillHeight: CGFloat = 52

    private var displayPct: Double { animatedPct ?? usage.percentage }
    private var isAPIToken: Bool { usage.billingType == .apiToken }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width

            ZStack(alignment: .leading) {
                // Background track
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: w, height: pillHeight)

                if !isAPIToken {
                    // Subscription/local: liquid fill progress bar
                    let hasProgress = displayPct > 0
                    let fillWidth = hasProgress ? max(pillHeight, w * CGFloat(displayPct / 100)) : 0
                    if hasProgress {
                        LiquidFill(percentage: displayPct, height: pillHeight)
                            .frame(width: fillWidth, height: pillHeight)
                            .clipShape(Capsule())
                            .animation(.spring(response: 0.7, dampingFraction: 0.82), value: displayPct)
                    }
                }

                // Left: stats text
                VStack(alignment: .leading, spacing: 2) {
                    if isAPIToken {
                        // API token: show cost as primary
                        Text(costLabel)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                            .monospacedDigit()
                        if let limit = usage.costLimitUSD, limit > 0 {
                            Text("of $\(Int(limit))")
                                .font(.system(size: 8, weight: .regular, design: .rounded))
                                .foregroundColor(.white.opacity(0.4))
                                .lineLimit(1)
                        } else {
                            Text("this month")
                                .font(.system(size: 8, weight: .regular, design: .rounded))
                                .foregroundColor(.white.opacity(0.4))
                        }
                    } else {
                        // Subscription/local: percentage as primary
                        let hasProgress = displayPct > 0
                        Text("\(Int(displayPct))%")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(hasProgress ? .white : .white.opacity(0.45))
                            .monospacedDigit()
                        if let detail = detailLabel {
                            Text(detail)
                                .font(.system(size: 8, weight: .regular, design: .rounded))
                                .foregroundColor(hasProgress ? .white.opacity(0.75) : .white.opacity(0.3))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                }
                .padding(.leading, 11)
                .frame(maxWidth: w - 34, alignment: .leading)

                // Right: app icon
                HStack(spacing: 0) {
                    Spacer()
                    Image(usage.provider.iconName)
                        .resizable()
                        .scaledToFit()
                        .foregroundColor(isAPIToken ? .white.opacity(0.5) : (displayPct > 0 ? .white : .white.opacity(0.4)))
                        .frame(width: 15, height: 15)
                        .padding(.trailing, 11)
                }
                .frame(width: w)
            }
        }
        .frame(height: pillHeight)
        .onAppear {
            guard !isAPIToken else { return }
            if !hasAnimatedIn {
                animatedPct = 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.spring(response: 0.75, dampingFraction: 0.8)) {
                        animatedPct = usage.percentage
                    }
                }
                hasAnimatedIn = true
            }
        }
        .onChange(of: usage.percentage) { newValue in
            guard !isAPIToken else { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                animatedPct = newValue
            }
        }
    }

    // MARK: - Labels

    private var costLabel: String {
        if let cost = usage.costUsedUSD {
            if cost < 0.01 && cost > 0 { return "$0.00" }
            return String(format: "$%.2f", cost)
        }
        return "$0.00"
    }

    private var detailLabel: String? {
        switch usage.billingType {
        case .apiToken:
            return nil  // handled inline
        case .subscription:
            if let used = usage.tokensUsed, let limit = usage.tokensLimit {
                return "\(fmt(used))/\(fmt(limit))"
            }
            if let used = usage.tokensUsed { return "\(fmt(used)) tok" }
            if usage.window == .session { return "ctx window" }
            return usage.window.displayName.lowercased()
        case .localUsage:
            if let used = usage.tokensUsed { return "\(fmt(used)) tok" }
            return nil
        }
    }

    private func fmt(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - Liquid fill

/// Two-layer liquid effect:
/// - Back layer: the dominant color for the current percentage range
/// - Front layer: the incoming next color, clipped to a blob whose right edge
///   has a slow sine-wave oscillation — looks like liquid pouring in from the front.
///   The blob width grows as the percentage moves deeper into each transition zone.
private struct LiquidFill: View {
    let percentage: Double   // 0–100, already animated by caller
    let height: CGFloat

    // 64×64 noise tile baked once at startup — tiled across the pill at render time
    static let noiseImage: CGImage? = {
        let side = 64
        let count = side * side
        var pixels = [UInt8](repeating: 0, count: count * 4)
        var seed: UInt32 = 0xA3B1_C2D4
        for i in 0..<count {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let v = UInt8(seed >> 24)          // 0–255 random luminance
            let alpha = UInt8(30 + (v % 40))   // 30–69 alpha (12–27% opacity)
            let base = i * 4
            pixels[base]     = v
            pixels[base + 1] = v
            pixels[base + 2] = v
            pixels[base + 3] = alpha
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: side, height: side,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )
    }()

    // Which transition zone are we in, and how far through it (0–1)?
    private var zone: (back: Color, front: Color, progress: Double) {
        let green  = Color(hex: "9cc900")
        let orange = Color(hex: "ff7c1e")
        let red    = Color(hex: "f53535")

        switch percentage {
        case 0..<50:
            // Pure green — no incoming color yet
            return (green, green, 0)
        case 50..<75:
            // Orange bleeding in, green receding — transition over 25 points
            let t = (percentage - 50) / 25
            return (green, orange, t)
        case 75...:
            // Red bleeding in, orange receding — transition over 25 points
            let t = min((percentage - 75) / 25, 1.0)
            return (orange, red, t)
        default:
            return (green, green, 0)
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { tl in
            let phase = tl.date.timeIntervalSinceReferenceDate
            let z = zone

            ZStack {
                // ── Layer 1: liquid color canvas, rasterized then blurred ──
                // drawingGroup() flattens into a Metal texture first so .blur()
                // only samples pixels within the layer — no black bleed from outside.
                Canvas { ctx, size in
                    ctx.fill(
                        Path(CGRect(origin: .zero, size: size)),
                        with: .color(z.front)
                    )

                    guard z.progress > 0 && z.progress < 1 else { return }

                    let blobWidth = size.width * CGFloat(1.0 - z.progress)
                    let amplitude: CGFloat = height * 0.22
                    let frequency: Double  = 1.4
                    let wavePhase          = phase * 0.9

                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: 0))
                    let steps = Int(size.height * 2)
                    for i in 0...steps {
                        let y = size.height * CGFloat(i) / CGFloat(steps)
                        let t = Double(i) / Double(steps)
                        let wave = amplitude * CGFloat(
                            sin(t * .pi * 2 * frequency + wavePhase) * 0.65 +
                            sin(t * .pi * 2 * frequency * 1.6 + wavePhase * 1.3) * 0.35
                        )
                        path.addLine(to: CGPoint(x: blobWidth + wave, y: y))
                    }
                    path.addLine(to: CGPoint(x: 0, y: size.height))
                    path.closeSubpath()
                    ctx.fill(path, with: .color(z.back))
                }
                .drawingGroup()   // rasterize into Metal texture — blur samples this, not scene behind
                .blur(radius: 6.4)

                // ── Layer 2: static noise texture overlay ──
                if let noise = LiquidFill.noiseImage {
                    Image(noise, scale: 1, label: Text(""))
                        .resizable(resizingMode: .tile)
                        .blendMode(.overlay)
                        .opacity(0.28)
                }
            }
        }
    }
}

// MARK: - Editable List (legacy — kept for settings screen)

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
