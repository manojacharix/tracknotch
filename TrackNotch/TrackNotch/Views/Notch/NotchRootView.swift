import SwiftUI

private let iconSize: CGFloat         = 22
private let iconGap: CGFloat          = 8
private let outerSidePadding: CGFloat = 12
private let innerSidePadding: CGFloat = 10

// Timing constants
private let pillExpandDelay:   Double = 0.0
private let iconExpandDelay:   Double = 0.12
private let iconCollapseDelay: Double = 0.0
private let pillCollapseDelay: Double = 0.18
private let staggerStep:       Double = 0.05

// Expanded notch dimensions
private let expandedMaxWidth:  CGFloat = 380
private let expandedTopRadius:    CGFloat = 10
private let expandedBottomRadius: CGFloat = 26

struct NotchRootView: View {
    let mode: NotchMode
    let onToggleDropdown: () -> Void

    @EnvironmentObject var registry: ProviderRegistry
    @EnvironmentObject var frameReporter: DropdownFrameReporter
    @State private var geo: NotchGeometry? = nil

    @State private var iconsVisible: Bool = false
    @State private var pillExpanded: Bool = false

    // Dropdown expansion state
    @State private var isExpanded: Bool = false
    @State private var contentVisible: Bool = false
    @State private var isEditMode: Bool = false
    @State private var transitionNonce: Int = 0
    /// Bumped on every expand() so NotchSlideIcon views can be force-recreated
    /// via .id(). Without this re-key, SwiftUI batches the iconsVisible
    /// false→true flip in expand() into a single render pass and the per-icon
    /// staggered onAppear/onChange animation never fires.
    @State private var expandCounter: Int = 0
    @State private var expandIconsWork: DispatchWorkItem? = nil
    @State private var collapsePillWork: DispatchWorkItem? = nil
    @State private var openExpandWork: DispatchWorkItem? = nil
    @State private var openContentWork: DispatchWorkItem? = nil
    @State private var closeCollapseWork: DispatchWorkItem? = nil
    @State private var closeRestoreWork: DispatchWorkItem? = nil
    /// Pending re-emerge work scheduled by the targetProviders.count change
    /// handler. Holds a single slot so back-to-back count changes (rapid
    /// hover-in / hover-out cycles) cancel the prior cycle instead of
    /// stacking multiple expandCounter bumps and timer fires — that
    /// stacking was the source of the "abrupt open/close" flicker the
    /// user observed when sweeping the cursor across the wing repeatedly.
    @State private var iconReemergeWork: DispatchWorkItem? = nil
    /// Single hover-settle timer. Any shouldShow change cancels this and
    /// schedules a new 300ms task. When it fires, compare current shouldShow
    /// to current visible state and animate only if they differ. Boundary
    /// wobble (enter/exit pairs <300ms apart) cancels itself out — no
    /// animation runs at all. Replaces the dual expand/collapse debounce
    /// pair which fired both directions independently.
    @State private var hoverSettleWork: DispatchWorkItem? = nil
    /// Timestamp of the most recent hover-driven expand() call. Used by
    /// openExpanded() to decide whether to snap the wing back to bare-notch
    /// before the morph (so the user sees one animation, not "wing slide-out
    /// then dropdown morph").
    @State private var lastHoverExpandTimestamp: TimeInterval = 0
    /// Snapshot of registry.stripEnterCount captured at closeExpanded().
    /// Combined with hoverGateAwaitingExit below, enforces the rule:
    /// "after a click-close, hover stays gated until the cursor has BOTH
    /// genuinely left the strip (shouldShow→false observed) AND then
    /// re-entered (stripEnterCount > baseline)." Event-counted gating is
    /// immune to mid-close timer races, but a count alone isn't enough
    /// because AppKit fires a spurious mouseEntered ~25ms after closing
    /// the dropdown (window reorder thrash). Requiring an exit first
    /// disqualifies that spurious enter.
    @State private var hoverGateBaseline: Int? = nil
    /// True while we're waiting for the cursor to genuinely leave the
    /// strip after closeExpanded(). Cleared only when shouldShow has
    /// remained false for ≥600ms continuously — brief "drifted off and
    /// came right back" exits within that window don't count as a real
    /// cursor leave. Until cleared, count-crossings of hoverGateBaseline
    /// are ignored.
    @State private var hoverGateAwaitingExit: Bool = false
    /// Pending work item that clears hoverGateAwaitingExit after a 600ms
    /// dwell. Cancelled if shouldShow flips back to true within the window
    /// (cursor came back too quickly — wasn't a real leave).
    @State private var hoverGateExitDwellWork: DispatchWorkItem? = nil

    private var isHovered: Bool { registry.isExternalHovered }

    private var targetProviders: [LLMProvider] {
        if isHovered || isExpanded {
            return registry.connectedProviders.filter { registry.usageMap[$0] != nil }
        }
        return registry.activeProviders
    }

    private var leftProviders:  [LLMProvider] { targetProviders.filter { $0.notchWing == .left } }
    private var rightProviders: [LLMProvider] { targetProviders.filter { $0.notchWing == .right } }

    private func wingWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * iconSize + CGFloat(count - 1) * iconGap + outerSidePadding + innerSidePadding
    }

    private var leftWingWidth:  CGFloat { pillExpanded && !isExpanded ? wingWidth(count: leftProviders.count) : 0 }
    private var rightWingWidth: CGFloat { pillExpanded && !isExpanded ? wingWidth(count: rightProviders.count) : 0 }
    private var pillHeight: CGFloat { geo?.notchHeight ?? 39 }

    private var pillWidth: CGFloat {
        if isExpanded { return expandedMaxWidth }
        guard let geo else { return geo?.notchWidth ?? 0 }
        return leftWingWidth + geo.notchWidth + rightWingWidth
    }

    private var pillLeadingOffset: CGFloat {
        if isExpanded { return (geo.map { $0.leftWingWidth + $0.notchWidth + $0.rightWingWidth } ?? expandedMaxWidth) / 2 - expandedMaxWidth / 2 }
        guard let geo else { return 0 }
        return geo.leftWingWidth - leftWingWidth
    }

    // Expanded height = content + notch bar height so the shape grows downward from notch bottom
    @State private var expandedContentHeight: CGFloat = 200

    private var notchShapeHeight: CGFloat {
        isExpanded ? pillHeight + expandedContentHeight : pillHeight
    }

    private var shouldShow: Bool { isHovered || !registry.activeProviders.isEmpty || isExpanded }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: geo.map { $0.leftWingWidth + $0.notchWidth + $0.rightWingWidth } ?? 580,
                       height: trackNotchWindowHeight)
                .allowsHitTesting(false)

            if let geo {
                pillView(geo: geo)
            }
        }
        .onAppear {
            Task { @MainActor in geo = notchGeometry() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .notchExpandDropdown)) { _ in
            NSLog("[TN.diag] NotchRootView got notchExpandDropdown — calling openExpanded")
            openExpanded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .notchCollapseDropdown)) { _ in
            #if DEBUG
            print("[NotchRootView] received notchCollapseDropdown")
            #endif
            closeExpanded()
        }
        .onChange(of: shouldShow) { show in
            NSLog("[TN.diag] shouldShow changed → \(show)")
            // While the dropdown is opening/open, hover state churn (cursor
            // "leaves" when click moves focus to NotchWindow) must NOT touch
            // the wing — would kill the dropdown's expand work item.
            if isExpanded || openExpandWork != nil {
                NSLog("[TN.diag] shouldShow change IGNORED — dropdown is opening/open")
                return
            }
            // Hover-after-close gate. Two-stage: must observe shouldShow→false
            // (cursor genuinely left strip) BEFORE a count-crossing of
            // hoverGateBaseline counts as a real fresh hover. Stage 1
            // disqualifies the spurious mouseEntered AppKit fires ~25ms
            // after close from window-reorder thrash. Stage 2 ensures the
            // re-enter is a real cursor return.
            if let baseline = hoverGateBaseline {
                if hoverGateAwaitingExit {
                    if !show {
                        // Cursor left strip. Start a 600ms dwell timer —
                        // only after shouldShow stays false continuously
                        // for that long do we consider it a real leave.
                        // A drift-off-and-back inside the window cancels.
                        hoverGateExitDwellWork?.cancel()
                        let work = DispatchWorkItem {
                            guard hoverGateAwaitingExit else { return }
                            // shouldShow must still be false at fire time.
                            guard !shouldShow else { return }
                            NSLog("[TN.diag] hoverGate stage1 — exit dwell satisfied, awaiting fresh enter (baseline rebased to \(registry.stripEnterCount))")
                            hoverGateAwaitingExit = false
                            // Rebase baseline to whatever count is now. Only
                            // enters AFTER this point can satisfy the gate.
                            hoverGateBaseline = registry.stripEnterCount
                        }
                        hoverGateExitDwellWork = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.60, execute: work)
                        NSLog("[TN.diag] hoverGate exit dwell started (600ms)")
                    } else {
                        // Cursor came back (or never really left). If a dwell
                        // timer was running, cancel it — this wasn't a real
                        // leave.
                        if hoverGateExitDwellWork != nil {
                            hoverGateExitDwellWork?.cancel()
                            hoverGateExitDwellWork = nil
                            NSLog("[TN.diag] hoverGate exit dwell CANCELLED — cursor came back")
                        }
                        NSLog("[TN.diag] shouldShow→true IGNORED — still awaiting genuine cursor leave (count=\(registry.stripEnterCount) baseline=\(baseline))")
                    }
                    hoverSettleWork?.cancel()
                    hoverSettleWork = nil
                    return
                }
                if registry.stripEnterCount > baseline {
                    NSLog("[TN.diag] hoverGate cleared — fresh enter (count=\(registry.stripEnterCount) > baseline=\(baseline))")
                    hoverGateBaseline = nil
                    // Fall through and process this shouldShow change normally.
                } else {
                    NSLog("[TN.diag] shouldShow→\(show) IGNORED — awaiting fresh strip enter (count=\(registry.stripEnterCount) baseline=\(baseline))")
                    hoverSettleWork?.cancel()
                    hoverSettleWork = nil
                    return
                }
            }
            // Asymmetric settle window. Enter is rarely spurious (cursor
            // really did arrive, animate quickly so it feels responsive);
            // exit is constantly spurious from boundary wobble (wait long
            // enough that any re-enter within the window cancels it). Any
            // shouldShow change cancels the prior timer; whatever shouldShow
            // is when the timer fires is the truth, and we only animate if
            // the visible state doesn't already match.
            hoverSettleWork?.cancel()
            // Asymmetric settle window. Enter: 80ms — fast so the wing
            // feels responsive on hover-in. Exit: 1100ms — long enough
            // that "drift off, come right back" gestures (which the user
            // perceives as a single hover) don't cause the wing to
            // visibly close-then-reopen. The previous 600ms window was
            // shorter than typical drift-and-return cycles (~700-900ms)
            // and produced abrupt close/open flicker. Any re-enter during
            // the window cancels the pending close; only sustained exits
            // commit to a collapse.
            let settleDelay: Double = show ? 0.08 : 1.10
            let work = DispatchWorkItem {
                guard !isExpanded, openExpandWork == nil else { return }
                if hoverGateBaseline != nil { return }
                let want = shouldShow
                let have = pillExpanded
                guard want != have else {
                    NSLog("[TN.diag] hoverSettle no-op — visible state already matches (want=\(want))")
                    return
                }
                // Cursor-truth check before collapsing. AppKit can fire a
                // spurious mouseExited (no follow-up enter) during wing
                // animation or layout settle — onHoverExit then flips
                // isExternalHovered=false, the 600ms settle lapses with no
                // re-enter, and we'd collapse a wing the user is still
                // parked over. Before committing to collapse, verify the
                // global cursor location really is outside the strip rect.
                // If still inside, restore hover state and bail.
                if !want, let strip = currentStripScreenRect() {
                    let cursor = NSEvent.mouseLocation
                    if strip.contains(cursor) {
                        NSLog("[TN.diag] hoverSettle SUPPRESSED collapse — cursor still inside strip (\(cursor) in \(strip)); restoring hover")
                        registry.isExternalHovered = true
                        return
                    }
                }
                if want { expand() } else { collapse() }
            }
            hoverSettleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: work)
        }
        // No explicit count-change handler. While the wing is out and the
        // icon set changes (e.g. activeProviders ↔ connectedProviders),
        // we let SwiftUI's natural ForEach diff handle it: providers
        // appearing in the new set mount fresh (NotchSlideIcon's onAppear
        // runs its slide-out animation, so the new icon visibly emerges
        // from the notch edge); providers leaving the set are removed
        // from the tree silently. The wing extent itself recomputes
        // smoothly via the existing pillWidth animation. Critically, no
        // global iconsVisible toggle runs — so existing icons that are
        // still in the new set are NOT re-animated. This eliminates the
        // "icons going inside the notch and coming out again" effect
        // that happened when the master visibility flag flipped while
        // the wing stayed visually open.
    }

    private func expand() {
        // No-op if expand is already in flight OR the pill is already out.
        // Previous guard only caught the fully-settled (pillExpanded &&
        // iconsVisible) state, so a hover bounce that re-fired expand()
        // while expandIconsWork was still pending would tear down and
        // restart — visible double slide-out. Treat any in-flight or
        // already-extended state as "we're going where you asked," noop.
        if pillExpanded || expandIconsWork != nil { return }
        cancelPendingWork()
        let nonce = beginTransition()
        lastHoverExpandTimestamp = ProcessInfo.processInfo.systemUptime
        // Force the wing icons to be re-created so their staggered slide-in
        // animation re-runs cleanly. SwiftUI batches iconsVisible false→true
        // into a single render pass otherwise, so the per-icon onAppear/
        // onChange stagger never gets a chance to fire.
        expandCounter &+= 1
        iconsVisible = false
        pillExpanded = false
        withAnimation(.interactiveSpring(response: 0.38, dampingFraction: 0.82, blendDuration: 0.1)) { pillExpanded = true }
        let work = DispatchWorkItem {
            guard transitionNonce == nonce else { return }
            withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.78, blendDuration: 0.08)) { iconsVisible = true }
        }
        expandIconsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + iconExpandDelay, execute: work)
    }

    private func collapse() {
        // Idempotency guard. If the wing isn't actually out, there's nothing
        // to collapse — bail before cancelling pending expand work that may
        // have just been scheduled by a fresh hover-on.
        if !pillExpanded { return }
        cancelPendingWork()
        let nonce = beginTransition()
        // Step 1: per-icon staggered slide back toward the notch — handled
        // inside NotchSlideIcon's onChange when iconsVisible flips false.
        // This is the exact reverse of the expand-side stagger (innermost
        // emerges first on hover-in → outermost retracts first on hover-out).
        iconsVisible = false
        // Step 2: once the icon stagger has played out, shrink the pill
        // back into the notch using the SAME spring as expand() — gives
        // the whole gesture mirrored timing. Wait window must cover the
        // worst-case innermost-icon settle: (maxCount-1)*staggerStep
        // (icon's own collapseDelay) + spring settle (~0.32s) + opacity
        // tail (0.10s). At 5 icons/side: 0.20 + 0.32 + 0.10 = 0.62s.
        // Anything shorter unmounts the wing subtree mid-slide and the
        // innermost icon's retraction is clipped to nothing instead of
        // being seen — making the staggered slide-back appear to "not
        // animate" past the first icon or two.
        let iconCollapseWindow: Double = 0.62
        let work = DispatchWorkItem {
            guard transitionNonce == nonce else { return }
            withAnimation(.interactiveSpring(response: 0.38, dampingFraction: 0.82, blendDuration: 0.1)) {
                pillExpanded = false
            }
        }
        collapsePillWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + iconCollapseWindow, execute: work)
    }

    // MARK: - Toggle expansion (called by NotchWindow on click)

    func openExpanded() {
        NSLog("[TN.diag] openExpanded entered isExpanded=\(isExpanded) contentVisible=\(contentVisible) iconsVisible=\(iconsVisible) pillExpanded=\(pillExpanded)")
        cancelPendingWork()
        let nonce = beginTransition()
        // Already fully expanded with content visible — no-op
        if isExpanded && contentVisible {
            NSLog("[TN.diag] openExpanded EARLY RETURN — already expanded")
            return
        }
        let alreadyShowing = pillExpanded && iconsVisible
        let sinceHoverExpand = ProcessInfo.processInfo.systemUptime - lastHoverExpandTimestamp

        // Fresh hover-expand still in flight (or just-finished). The wing has
        // visibly slid out within the last 250ms — if we now morph from that
        // state the user sees TWO motions (hover slide-out → dropdown morph).
        // Snap back to bare notch non-animated, then run the cold-path morph
        // so the dropdown appears to grow straight from the notch as one motion.
        if pillExpanded && sinceHoverExpand < 0.25 {
            NSLog("[TN.diag] openExpanded snapping pre-hover state (sinceHoverExpand=\(sinceHoverExpand))")
            iconsVisible = false
            pillExpanded = false
            // Fall through to cold-path morph below.
        } else if alreadyShowing {
            // Settled hover. Wings have been visible for >250ms, so the user
            // already perceives them as the resting state — fast-path morph
            // (drop wings from tree as the pill grows downward) is one motion.
            iconsVisible = false  // non-animated; icons exit with the wing subtree
            let expandWork = DispatchWorkItem { [self] in
                guard transitionNonce == nonce else { NSLog("[TN.diag] openExpanded fastpath CANCELLED"); return }
                NSLog("[TN.diag] openExpanded fastpath morph running")
                withAnimation(.interactiveSpring(response: 0.5, dampingFraction: 0.85, blendDuration: 0.12)) {
                    isExpanded = true
                    pillExpanded = true
                }
                let contentWork = DispatchWorkItem { [self] in
                    guard transitionNonce == nonce else { return }
                    NSLog("[TN.diag] openExpanded contentWork running — flipping contentVisible=true")
                    withAnimation(.easeOut(duration: 0.2)) { contentVisible = true }
                }
                openContentWork = contentWork
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: contentWork)
            }
            openExpandWork = expandWork
            // Next-runloop hop so the non-animated iconsVisible flag commits
            // before SwiftUI batches it into the spring transaction.
            DispatchQueue.main.async(execute: expandWork)
            return
        }

        // Cold path: wings not visible (no prior hover). Keep the icon-fade
        // prelude — harmless when nothing's drawn, gives the morph a moment.
        let iconFadeDuration: Double = 0.12
        let expandDelay:       Double = 0.10
        withAnimation(.easeOut(duration: iconFadeDuration)) { iconsVisible = false }
        let expandWork = DispatchWorkItem { [self] in
            guard transitionNonce == nonce else { NSLog("[TN.diag] openExpanded expandWork CANCELLED (nonce mismatch)"); return }
            NSLog("[TN.diag] openExpanded expandWork running (cold)")
            withAnimation(.interactiveSpring(response: 0.5, dampingFraction: 0.85, blendDuration: 0.12)) {
                isExpanded = true
                pillExpanded = true
            }
            let contentWork = DispatchWorkItem { [self] in
                guard transitionNonce == nonce else { NSLog("[TN.diag] openExpanded contentWork CANCELLED"); return }
                NSLog("[TN.diag] openExpanded contentWork running — flipping contentVisible=true")
                withAnimation(.easeOut(duration: 0.2)) { contentVisible = true }
            }
            openContentWork = contentWork
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: contentWork)
        }
        openExpandWork = expandWork
        DispatchQueue.main.asyncAfter(deadline: .now() + expandDelay, execute: expandWork)
    }

    func closeExpanded() {
        NSLog("[TN.diag] closeExpanded entered isExpanded=\(isExpanded) iconsVisible=\(iconsVisible)")
        guard isExpanded else { return }
        // Snapshot the strip enter count and require an exit-then-enter
        // cycle before hover can fire again. Just a count crossing isn't
        // enough — AppKit fires a spurious mouseEntered within ~25ms of
        // dropdown close from window-reorder thrash, which would falsely
        // satisfy a count-only gate. Requiring an exit first means the
        // user must actually move cursor away then back.
        hoverGateBaseline = registry.stripEnterCount
        hoverGateAwaitingExit = true
        NSLog("[TN.diag] closeExpanded — hoverGateBaseline=\(registry.stripEnterCount) awaitingExit=true")
        cancelPendingWork()
        let nonce = beginTransition()
        isEditMode = false
        // Fade content out, then shrink shape back to pill, then restore wing icons
        withAnimation(.easeInOut(duration: 0.18)) { contentVisible = false }
        let collapseWork = DispatchWorkItem {
            guard transitionNonce == nonce else { return }
            // Flip BOTH state flags inside one spring transaction. Critical:
            // pillExpanded must go false in the same animation as isExpanded.
            // If pillExpanded is left true while isExpanded flips false, the
            // wing subtree (gated on `pillExpanded && !isExpanded`) re-enters
            // the view tree for ~300ms before restoreWork shrinks it — the
            // user perceives this as a wing flashing open during the close.
            iconsVisible = false
            withAnimation(.interactiveSpring(response: 0.48, dampingFraction: 0.88, blendDuration: 0.1)) {
                isExpanded = false
                pillExpanded = false
            }
        }
        closeCollapseWork = collapseWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: collapseWork)
    }

    /// Recompute the strip panel's screen-space rect on demand. Used by the
    /// hover-settle work to verify cursor truth before committing to a
    /// collapse — bypasses any stale isExternalHovered flag and the
    /// AppKit tracking-area state that can lie about cursor position
    /// during animation. Mirrors NotchWindow.hardwareStripRect's geometry.
    private func currentStripScreenRect() -> NSRect? {
        guard let geo, let screen = NSScreen.main else { return nil }
        let sf = screen.frame
        let stripHeight = geo.notchHeight + 4
        // Use the FULL connected wing extent (matches NotchWindow stable
        // strip frame). Add a small horizontal pad so a cursor parked
        // exactly at the visual edge still counts as inside.
        let visibleProviders = registry.connectedProviders.filter { registry.usageMap[$0] != nil }
        let leftCount  = visibleProviders.filter { $0.notchWing == .left  }.count
        let rightCount = visibleProviders.filter { $0.notchWing == .right }.count
        let leftW  = wingWidth(count: leftCount)
        let rightW = wingWidth(count: rightCount)
        let contentW = max(geo.notchWidth, leftW + geo.notchWidth + rightW)
        let pad: CGFloat = 6
        let centerX = sf.origin.x + sf.width / 2
        return NSRect(
            x: centerX - contentW / 2 - pad,
            y: sf.origin.y + sf.height - stripHeight,
            width: contentW + pad * 2,
            height: stripHeight
        )
    }

    private func cancelPendingWork() {
        NSLog("[TN.diag] cancelPendingWork called — openExpandWork=\(openExpandWork != nil) expandIconsWork=\(expandIconsWork != nil) collapsePillWork=\(collapsePillWork != nil)")
        expandIconsWork?.cancel()
        expandIconsWork = nil
        collapsePillWork?.cancel()
        collapsePillWork = nil
        openExpandWork?.cancel()
        openExpandWork = nil
        openContentWork?.cancel()
        openContentWork = nil
        closeCollapseWork?.cancel()
        closeCollapseWork = nil
        closeRestoreWork?.cancel()
        closeRestoreWork = nil
        hoverSettleWork?.cancel()
        hoverSettleWork = nil
        iconReemergeWork?.cancel()
        iconReemergeWork = nil
    }

    @discardableResult
    private func beginTransition() -> Int {
        transitionNonce += 1
        return transitionNonce
    }

    // MARK: - Pill

    @ViewBuilder
    private func pillView(geo: NotchGeometry) -> some View {
        let totalWidth = geo.leftWingWidth + geo.notchWidth + geo.rightWingWidth

        ZStack(alignment: .top) {
            // The single notch shape — animates between pill and expanded card
            NotchShape(topCornerRadius: isExpanded ? expandedTopRadius : 6,
                       bottomCornerRadius: isExpanded ? expandedBottomRadius : 14)
                .fill(Color.black)
                .frame(width: pillWidth, height: notchShapeHeight)
                .shadow(color: .black.opacity(isExpanded ? 0.7 : 0.5),
                        radius: isExpanded ? 24 : 8,
                        y: isExpanded ? 10 : 0)
                .animation(.interactiveSpring(response: 0.45, dampingFraction: 0.82, blendDuration: 0.1), value: pillWidth)
                .animation(.interactiveSpring(response: 0.45, dampingFraction: 0.82, blendDuration: 0.1), value: notchShapeHeight)
                .animation(.interactiveSpring(response: 0.45, dampingFraction: 0.82, blendDuration: 0.1), value: isExpanded)

            // Wing icons (idle/hover state) — hidden while expanded
            // Always in tree while pill is expanded so child dissolve animations can play
            if pillExpanded && !isExpanded {
                wingContent(geo: geo)
                    .frame(width: pillWidth, height: pillHeight)
                    .allowsHitTesting(false)
            }

            // When expanded: edit (left) and settings (right) flanking the notch.
            // Use the physical notch width as the centre gap so both buttons
            // sit symmetrically in the wing zones on either side.
            if isExpanded {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)

                    // Edit button — right side of left wing, close to notch
                    ZStack {
                        Button(isEditMode ? "done" : "edit") {
                            isEditMode.toggle()
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                        .contentShape(Capsule())
                    }
                    .padding(.trailing, 10)

                    // Physical notch gap — tap to close dropdown
                    Color.white.opacity(0.001)
                        .frame(width: geo.notchWidth, height: pillHeight)
                        .contentShape(Rectangle())
                        .onTapGesture { onToggleDropdown() }

                    // Settings button — left side of right wing, close to notch
                    ZStack {
                        Button("settings") {
                            // Don't toggle the dropdown here — opening the
                            // dialog makes it key, NotchWindow.resignKey()
                            // handles the collapse via closeDropdown(). Doing
                            // both would leave isDropdownVisible out of sync
                            // with SwiftUI's isExpanded.
                            ConnectionWindowController.shared.open()
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                        .contentShape(Capsule())
                    }
                    .padding(.leading, 10)

                    Spacer(minLength: 0)
                }
                .frame(width: pillWidth, height: pillHeight)
                .opacity(contentVisible ? 1 : 0)
            }

            // Expanded dropdown content — sits below the notch bar inside the shape
            if isExpanded {
                VStack(spacing: 0) {
                    // Spacer for the physical notch bar height
                    Color.clear.frame(height: pillHeight)

                    DropdownContent(onDismiss: { onToggleDropdown() }, isEditMode: $isEditMode)
                        .padding(.top, 8)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 8)
                        .opacity(contentVisible ? 1 : 0)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.onAppear {
                                    expandedContentHeight = proxy.size.height
                                }.onChange(of: proxy.size.height) { h in
                                    expandedContentHeight = h
                                }
                            }
                        )
                }
                .frame(width: pillWidth)
                .clipped()
            }
        }
        .frame(width: pillWidth, height: notchShapeHeight, alignment: .top)
        .offset(x: pillLeadingOffset)
        .animation(.interactiveSpring(response: 0.45, dampingFraction: 0.82, blendDuration: 0.1), value: pillLeadingOffset)
        // Pass all events through to StripPanel when collapsed; interactive when expanded
        .allowsHitTesting(isExpanded)
    }

    // MARK: - Wing content

    @ViewBuilder
    private func wingContent(geo: NotchGeometry) -> some View {
        HStack(spacing: 0) {
            if !leftProviders.isEmpty {
                HStack(spacing: iconGap) {
                    Spacer(minLength: 0)
                    ForEach(Array(leftProviders.enumerated()), id: \.element) { idx, provider in
                        if let usage = registry.usageMap[provider] {
                            let expandDelay   = Double(leftProviders.count - 1 - idx) * staggerStep
                            let collapseDelay = Double(idx) * staggerStep
                            NotchSlideIcon(usage: usage, direction: .right,
                                           expandDelay: expandDelay, collapseDelay: collapseDelay,
                                           isShowing: iconsVisible)
                                .id("left-\(provider.rawValue)-\(expandCounter)")
                        }
                    }
                }
                .padding(.leading, outerSidePadding)
                .padding(.trailing, innerSidePadding)
                .frame(width: leftWingWidth, height: pillHeight, alignment: .center)
                .clipped()
            }

            Color.clear.frame(width: geo.notchWidth, height: pillHeight)

            if !rightProviders.isEmpty {
                HStack(spacing: iconGap) {
                    ForEach(Array(rightProviders.enumerated()), id: \.element) { idx, provider in
                        if let usage = registry.usageMap[provider] {
                            // Outermost icon (highest idx) slides in FIRST,
                            // mirroring the left wing's stagger and matching
                            // how slide-out plays in reverse.
                            let expandDelay   = Double(rightProviders.count - 1 - idx) * staggerStep
                            let collapseDelay = Double(rightProviders.count - 1 - idx) * staggerStep
                            NotchSlideIcon(usage: usage, direction: .left,
                                           expandDelay: expandDelay, collapseDelay: collapseDelay,
                                           isShowing: iconsVisible)
                                .id("right-\(provider.rawValue)-\(expandCounter)")
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, innerSidePadding)
                .padding(.trailing, outerSidePadding)
                .frame(width: rightWingWidth, height: pillHeight, alignment: .center)
                .clipped()
            }
        }
    }
}

// MARK: - NotchSlideIcon

private enum SlideDirection { case left, right }

private struct NotchSlideIcon: View {
    let usage: ProviderUsage
    let direction: SlideDirection
    let expandDelay: Double
    let collapseDelay: Double
    let isShowing: Bool

    /// Drives the horizontal offset (slide). Animated with a spring on
    /// both directions — the slide is the dominant motion the user reads.
    @State private var slidIn = false
    /// Drives opacity. Decoupled from `slidIn` so we can hold opacity at
    /// 1 during the entire slide-back and let the wing's `.clipped()`
    /// mask the icon as it crosses the notch edge — without this the
    /// icon would fade out mid-air before reaching the notch.
    @State private var faded = false
    private let slideDistance: CGFloat = 36

    private var hiddenOffset: CGFloat {
        direction == .right ? slideDistance : -slideDistance
    }

    var body: some View {
        WingIconView(usage: usage)
            .opacity(faded ? 1 : 0)
            .offset(x: slidIn ? 0 : hiddenOffset)
            .onAppear {
                slidIn = false
                faded = false
                DispatchQueue.main.asyncAfter(deadline: .now() + expandDelay) {
                    withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.78, blendDuration: 0.08)) {
                        slidIn = true
                        faded = true
                    }
                }
            }
            .onChange(of: isShowing) { showing in
                if showing {
                    // Slide-out (hover-in): icon flies from inside the
                    // notch to its settled wing position. Opacity ramps
                    // up alongside the slide so it appears to materialize
                    // as it crosses the notch edge.
                    slidIn = false
                    faded = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + expandDelay) {
                        withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.78, blendDuration: 0.08)) {
                            slidIn = true
                            faded = true
                        }
                    }
                } else {
                    // Slide-in (hover-out): exact reverse — icon retracts
                    // toward the notch using the SAME spring. Opacity is
                    // held at 1 during the slide so the icon visibly
                    // travels into the notch (the wing's .clipped() mask
                    // hides it past the boundary). Opacity drops to 0 in
                    // a brief tail at the END of the slide so any pixel
                    // still escaping the clip mask vanishes cleanly.
                    DispatchQueue.main.asyncAfter(deadline: .now() + collapseDelay) {
                        withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.78, blendDuration: 0.08)) {
                            slidIn = false
                        }
                        // Opacity tail — runs after the spring is mostly
                        // settled, fades from 1 to 0 over a short window.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
                            withAnimation(.easeOut(duration: 0.10)) {
                                faded = false
                            }
                        }
                    }
                }
            }
    }
}

// MARK: - Previews

#Preview("Pill shape") {
    ZStack(alignment: .top) {
        Color.white.opacity(0.15)
        NotchShape(topCornerRadius: 6, bottomCornerRadius: 14)
            .fill(Color.black)
            .frame(width: 200, height: 39)
            .overlay {
                NotchShape(topCornerRadius: 6, bottomCornerRadius: 14)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            }
    }
    .frame(width: 600, height: 60)
    .background(Color.gray.opacity(0.4))
}

#Preview("Wing active") {
    let usage = ProviderUsage(
        provider: .claudeCode, billingType: .subscription, window: .weekly,
        percentage: 45, resetsAt: nil, tokensUsed: 50000, tokensLimit: 2500000,
        costUsedUSD: nil, costLimitUSD: nil, modelBreakdown: [], fetchedAt: Date(),
        isActivelyConsuming: true
    )
    return ZStack(alignment: .top) {
        Color.white.opacity(0.15)
        HStack(spacing: 0) {
            Spacer()
            NotchShape(topCornerRadius: 6, bottomCornerRadius: 14)
                .fill(Color.black)
                .frame(width: 244, height: 39)
                .overlay {
                    HStack {
                        Spacer().frame(width: 210)
                        WingIconView(usage: usage)
                    }
                }
            Spacer()
        }
    }
    .frame(width: 600, height: 60)
    .background(Color.gray.opacity(0.4))
}
