import SwiftUI
import PhosphorSwift
import UniformTypeIdentifiers

/// Stable identity for a single dropdown grid cell. A provider that
/// publishes both a primary (e.g. 5h) and secondary (e.g. weekly) quota
/// renders as TWO independent cells with distinct keys, so the user can
/// reorder them separately. Wing-side `orderedProviders` is unaffected
/// — that remains a single ordering of `LLMProvider`.
struct DropdownCellKey: Hashable, Codable {
    let provider: LLMProvider
    let secondary: Bool

    /// Stable string for UserDefaults / drag pasteboard.
    var serialized: String { "\(provider.rawValue)|\(secondary ? "s" : "p")" }

    init(provider: LLMProvider, secondary: Bool) {
        self.provider = provider
        self.secondary = secondary
    }

    init?(serialized s: String) {
        let parts = s.split(separator: "|")
        guard parts.count == 2,
              let p = LLMProvider(rawValue: String(parts[0])) else { return nil }
        self.provider = p
        self.secondary = parts[1] == "s"
    }
}

/// Content rendered inside the expanded notch shape.
/// No background or shadow — those are owned by NotchRootView's NotchShape.
struct DropdownContent: View {
    var onDismiss: (() -> Void)? = nil
    @Binding var isEditMode: Bool
    @EnvironmentObject var registry: ProviderRegistry
    @State private var cellOrder: [DropdownCellKey] = []
    @State private var draggingCell: DropdownCellKey? = nil
    @State private var dropTargetCell: DropdownCellKey? = nil

    private static let cellOrderKey = "dropdownCellOrder"

    /// Cells the registry currently has data for, in the user-defined order.
    private var visibleCells: [DropdownCell] {
        cellOrder.compactMap { key in
            guard registry.connectedProviders.contains(key.provider) else { return nil }
            guard let usage = registry.usageMap[key.provider] else { return nil }
            // Primary only renders if percentage is meaningful (always true).
            // Secondary renders only when secondaryPercentage exists and the
            // provider isn't an API-token billing type.
            if key.secondary {
                guard usage.secondaryPercentage != nil,
                      usage.billingType != .apiToken else { return nil }
            }
            return DropdownCell(key: key, usage: usage)
        }
    }

    private let columns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]

    var body: some View {
        VStack(spacing: 0) {
            if visibleCells.isEmpty {
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
                    ForEach(Array(visibleCells.enumerated()), id: \.element) { idx, cell in
                        pillCell(cell: cell, index: idx)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 2)
            }
        }
        .animation(.interactiveSpring(response: 0.32, dampingFraction: 0.8, blendDuration: 0.08), value: isEditMode)
        .onAppear {
            loadCellOrder()
            syncCellOrder()
        }
        .onChange(of: registry.usageMap.count) { _ in syncCellOrder() }
        .onChange(of: isEditMode) { editing in
            if !editing { saveCellOrder() }
        }
    }

    @ViewBuilder
    private func pillCell(cell: DropdownCell, index: Int) -> some View {
        HStack(spacing: 4) {
            if isEditMode {
                Ph.dotsSixVertical.bold
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12, height: 12)
                    .foregroundColor(.white.opacity(0.3))
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            DropdownProviderPill(usage: cell.usage, isEditMode: isEditMode, appearIndex: index, secondary: cell.key.secondary)
        }
        .opacity(draggingCell == cell.key ? 0.4 : 1)
        .overlay(
            dropTargetCell == cell.key && draggingCell != cell.key
                ? RoundedRectangle(cornerRadius: 26)
                    .stroke(Color.white.opacity(0.3), lineWidth: 1.5)
                : nil
        )
        .onDrag {
            draggingCell = cell.key
            return NSItemProvider(object: cell.key.serialized as NSString)
        }
        .onDrop(of: [UTType.text], delegate: CellDropDelegate(
            target: cell.key,
            cells: $cellOrder,
            dragging: $draggingCell,
            dropTarget: $dropTargetCell
        ))
    }

    /// Reconcile `cellOrder` against current registry state. Adds new cells
    /// (newly-connected providers; dual-quota providers gaining a secondary
    /// window) and prunes ones that are no longer applicable.
    private func syncCellOrder() {
        // Build the canonical set of cells the registry can produce.
        var canonical: [DropdownCellKey] = []
        for provider in registry.orderedProviders {
            guard let usage = registry.usageMap[provider] else { continue }
            canonical.append(DropdownCellKey(provider: provider, secondary: false))
            if usage.secondaryPercentage != nil && usage.billingType != .apiToken {
                canonical.append(DropdownCellKey(provider: provider, secondary: true))
            }
        }
        let canonicalSet = Set(canonical)
        // Drop entries from local order that no longer exist in canonical.
        cellOrder.removeAll { !canonicalSet.contains($0) }
        // Append any canonical entries we don't yet have, preserving the
        // canonical ordering for new arrivals.
        let existing = Set(cellOrder)
        for key in canonical where !existing.contains(key) {
            cellOrder.append(key)
        }
    }

    private func loadCellOrder() {
        guard let raw = UserDefaults.standard.array(forKey: Self.cellOrderKey) as? [String] else { return }
        cellOrder = raw.compactMap(DropdownCellKey.init(serialized:))
    }

    private func saveCellOrder() {
        let raw = cellOrder.map(\.serialized)
        UserDefaults.standard.set(raw, forKey: Self.cellOrderKey)
    }
}

/// One row in the dropdown grid. Dual-quota providers emit two cells with
/// distinct `DropdownCellKey`s (one primary, one secondary) so the user
/// can reorder them independently.
private struct DropdownCell: Hashable {
    let key: DropdownCellKey
    let usage: ProviderUsage

    func hash(into hasher: inout Hasher) { hasher.combine(key) }
    static func == (lhs: DropdownCell, rhs: DropdownCell) -> Bool { lhs.key == rhs.key }
}

// MARK: - Drop delegate for grid reorder

private struct CellDropDelegate: DropDelegate {
    let target: DropdownCellKey
    @Binding var cells: [DropdownCellKey]
    @Binding var dragging: DropdownCellKey?
    @Binding var dropTarget: DropdownCellKey?

    func dropEntered(info: DropInfo) { dropTarget = target }
    func dropExited(info: DropInfo)  { if dropTarget == target { dropTarget = nil } }

    func performDrop(info: DropInfo) -> Bool {
        defer { dragging = nil; dropTarget = nil }
        guard let from = dragging,
              let fromIdx = cells.firstIndex(of: from),
              let toIdx   = cells.firstIndex(of: target),
              fromIdx != toIdx
        else { return false }
        withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.8, blendDuration: 0.08)) {
            cells.move(fromOffsets: IndexSet(integer: fromIdx), toOffset: toIdx > fromIdx ? toIdx + 1 : toIdx)
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
    /// Stagger index — pills animate in sequence, not all at once
    var appearIndex: Int = 0
    /// When true, render the secondary window (e.g. 7d) instead of the primary
    /// (5h). Used by DropdownContent to emit two cells for dual-quota providers.
    var secondary: Bool = false

    @State private var animatedPct: Double?
    @State private var contentOpacity: Double = 0

    private let pillHeight: CGFloat = 52

    /// The percentage this pill renders — primary or secondary depending on mode.
    private var sourcePercentage: Double {
        secondary ? (usage.secondaryPercentage ?? 0) : usage.percentage
    }

    private var displayPct: Double { animatedPct ?? 0 }
    private var isAPIToken: Bool { usage.billingType == .apiToken }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width

            // Single-bar layout. Dual-quota providers are rendered as TWO
            // sibling cells from DropdownContent (one with secondary=false,
            // one with secondary=true), so each pill stays uncluttered.
            ZStack(alignment: .leading) {
                    // Background track
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: w, height: pillHeight)

                    if !isAPIToken {
                        // Subscription/local: liquid fill progress bar
                        let hasProgress = displayPct > 0
                        // Clamp fill to the pill's own width so percentages
                        // above 100% (e.g. rate-limit hit at 123%) don't
                        // overflow past the capsule into the icon area.
                        // The percentage text still shows the true value.
                        let fillWidth = hasProgress ? min(w, w * CGFloat(displayPct / 100)) : 0
                        if hasProgress {
                            LiquidFill(percentage: displayPct, height: pillHeight)
                                .frame(width: fillWidth, height: pillHeight)
                                .clipShape(Capsule())
                                .animation(.easeOut(duration: 0.6), value: displayPct)
                        }
                    }

                    // Left: stats text
                    VStack(alignment: .leading, spacing: 2) {
                        if isAPIToken {
                            // API token: show cost as primary, or note if org-only tracking
                            if usage.fetchError == "orgs_only" {
                                Text("—")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundColor(.white.opacity(0.45))
                                Text("orgs only")
                                    .font(.system(size: 8, weight: .regular, design: .rounded))
                                    .foregroundColor(.white.opacity(0.3))
                            } else {
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
                            }
                        } else {
                            // Subscription/local: percentage as primary.
                            // Text is white at 0–10% (fill is thin/absent, dark bg shows through).
                            // Above 10% the fill covers the text area — switch to dark charcoal.
                            let onFill = displayPct > 10
                            Text("\(Int(displayPct))%")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundColor(onFill ? Color(hex: "252728") : .white.opacity(displayPct > 0 ? 1 : 0.45))
                                .monospacedDigit()
                            if let detail = detailLabel {
                                Text(detail)
                                    .font(.system(size: 8, weight: .regular, design: .rounded))
                                    .foregroundColor(onFill ? Color(hex: "252728").opacity(0.7) : .white.opacity(displayPct > 0 ? 0.75 : 0.3))
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                        }
                    }
                    .padding(.leading, 11)
                    .frame(maxWidth: w - 34, alignment: .leading)
                    .opacity(contentOpacity)

                    // Right: app icon + error dot
                    HStack(spacing: 0) {
                        Spacer()
                        ZStack(alignment: .topTrailing) {
                            Image(usage.provider.iconName)
                                .resizable()
                                .scaledToFit()
                                .foregroundColor(isAPIToken ? .white.opacity(0.5) : (displayPct > 0 ? .white : .white.opacity(0.4)))
                                .frame(width: 15, height: 15)
                            if let err = usage.fetchError, err != "orgs_only" {
                                Circle()
                                    .fill(Color(hex: "fb4141"))
                                    .frame(width: 5, height: 5)
                                    .offset(x: 2, y: -2)
                            }
                        }
                        .padding(.trailing, 11)
                    }
                    .frame(width: w)
                    .opacity(contentOpacity)
                }
        }
        .frame(height: pillHeight)
        .onAppear {
            // Reset to 0 every time the pill appears (dropdown opens)
            animatedPct = 0
            contentOpacity = 0

            // Staggered delay: each pill waits a bit longer
            let delay = 0.08 + Double(appearIndex) * 0.06

            // Fade in text/icon quickly
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.easeOut(duration: 0.25)) {
                    contentOpacity = 1
                }
            }

            // Fill animates from 0 to the relevant usage (primary or secondary)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.05) {
                withAnimation(.easeOut(duration: 0.7)) {
                    animatedPct = sourcePercentage
                }
            }
        }
        .onDisappear {
            // Reset so next open replays the animation
            animatedPct = 0
            contentOpacity = 0
        }
        .onChange(of: usage.percentage) { newValue in
            // Live updates while dropdown is open
            withAnimation(.easeOut(duration: 0.5)) {
                animatedPct = secondary ? (usage.secondaryPercentage ?? 0) : newValue
            }
        }
        .onChange(of: usage.secondaryPercentage) { newValue in
            guard secondary else { return }
            withAnimation(.easeOut(duration: 0.5)) {
                animatedPct = newValue ?? 0
            }
        }
    }

    // MARK: - Labels

    /// Window name for the primary (5h) bar — e.g. "5-hour".
    private var primaryWindowLabel: String { usage.window.displayName }

    /// Reset countdown for the primary bar — e.g. "4h 50m".
    private var primaryResetLabel: String { usage.formattedResetsIn }

    /// Window name for the secondary (7d) bar — e.g. "Weekly".
    private var secondaryWindowLabel: String { usage.secondaryWindow?.displayName ?? "Weekly" }

    /// Reset countdown for the secondary bar — e.g. "3d 4h".
    private var secondaryResetLabel: String {
        guard let r = usage.secondaryResetsAt else { return "—" }
        let seconds = r.timeIntervalSinceNow
        guard seconds > 0 else { return "—" }
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        if h >= 24 { return "\(h / 24)d \(h % 24)h" }
        if h > 0   { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private var costLabel: String {
        if let cost = usage.costUsedUSD {
            if cost < 0.01 && cost > 0 { return "< $0.01" }
            return String(format: "$%.2f", cost)
        }
        return "$0.00"
    }

    private var detailLabel: String? {
        // Secondary cell (7d): show window name + reset countdown only.
        if secondary {
            return "\(secondaryWindowLabel) \(secondaryResetLabel)"
        }

        switch usage.billingType {
        case .apiToken:
            return nil  // handled inline
        case .subscription:
            // Primary cell with real rate-limit data: show window + reset.
            // The 7d figure now lives in its own sibling cell, so no append.
            if usage.window == .fiveHour, usage.resetsAt != nil {
                return "\(primaryWindowLabel) \(primaryResetLabel)"
            }
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

    /// Wave animation only needed when between two color zones (progress 0–1).
    private var needsAnimation: Bool {
        let z = zone
        return z.progress > 0 && z.progress < 1
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: needsAnimation ? 1.0 / 30.0 : 1.0)) { tl in
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
                    let wavePhase          = phase * 2.2

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

