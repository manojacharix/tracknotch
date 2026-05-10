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
private let staggerStep:       Double = 0.025

// Expanded notch dimensions
private let expandedMaxWidth:  CGFloat = 420
private let expandedTopRadius:    CGFloat = 10
private let expandedBottomRadius: CGFloat = 26

struct NotchRootView: View {
    let mode: NotchMode
    let onToggleDropdown: () -> Void

    @EnvironmentObject var registry: ProviderRegistry
    @EnvironmentObject var frameReporter: DropdownFrameReporter
    @EnvironmentObject var windowHoverState: WindowHoverState
    @State private var geo: NotchGeometry? = nil

    @State private var iconsVisible: Bool = false
    @State private var pillExpanded: Bool = false
    /// Wing provider counts frozen at expand() time so late-arriving usageMap
    /// entries don't grow renderedProviders mid-animation and shift layout.
    /// Cleared to nil on collapse so next expand gets a fresh snapshot.
    @State private var frozenLeftCount:  Int? = nil
    @State private var frozenRightCount: Int? = nil

    /// Per-icon slide state, keyed by provider. Parent owns this so the
    /// per-icon spring animation runs reliably from prop changes via
    /// `.animation(value:)` in NotchSlideIcon — replaces the previous
    /// `.onChange(of: isShowing)` pattern which silently failed to fire
    /// on the slide-back transition (logged proof in TN.diag traces).
    /// `true` = icon slid out (visible at offset 0). `false` = retracted
    /// (at hiddenOffset, opacity 0 — clipped by wing's `.clipped()`).
    @State private var iconSlideState: [LLMProvider: Bool] = [:]
    /// Pending per-icon stagger work items. Tracked so a fresh transition
    /// (e.g. hover-in mid-collapse) can cancel in-flight staggers cleanly
    /// before kicking off a new sequence.
    @State private var iconStaggerWorkItems: [DispatchWorkItem] = []

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
    /// Snapshot of windowHoverState.stripEnterCount captured at closeExpanded().
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

    private var isHovered: Bool { windowHoverState.isHovered }

    private var targetProviders: [LLMProvider] {
        if isHovered || isExpanded {
            return registry.connectedProviders.filter { registry.usageMap[$0] != nil }
        }
        return registry.activeProviders
    }

    /// Set form of targetProviders — used as the `onChange` value so SwiftUI
    /// can detect when providers are added or removed while the pill is live.
    private var targetProviderSet: Set<LLMProvider> { Set(targetProviders) }

    /// Providers currently in the wing view tree. Union of `targetProviders`
    /// and any provider still tracked in `iconSlideState` — the latter
    /// includes icons mid-animation (sliding back into the notch). Without
    /// this union, hover-out instantly drops connected-only icons from
    /// `targetProviders` → they vanish from the ForEach before collapse()
    /// can stagger their slide-back. Preserves order from connectedProviders
    /// so left/right partitioning stays stable.
    private var renderedProviders: [LLMProvider] {
        let target = targetProviders
        let inFlight = Set(iconSlideState.keys)
        let extras = registry.connectedProviders.filter {
            inFlight.contains($0) && !target.contains($0) && registry.usageMap[$0] != nil
        }
        return target + extras
    }

    private var leftProviders:  [LLMProvider] { renderedProviders.filter { $0.notchWing == .left } }
    private var rightProviders: [LLMProvider] { renderedProviders.filter { $0.notchWing == .right } }

    private func wingWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * iconSize + CGFloat(count - 1) * iconGap + outerSidePadding + innerSidePadding
    }

    private var leftWingWidth:  CGFloat { pillExpanded && !isExpanded ? wingWidth(count: frozenLeftCount  ?? leftProviders.count)  : 0 }
    private var rightWingWidth: CGFloat { pillExpanded && !isExpanded ? wingWidth(count: frozenRightCount ?? rightProviders.count) : 0 }
    private var pillHeight: CGFloat { geo?.notchHeight ?? 39 }

    private var pillWidth: CGFloat {
        if isExpanded { return expandedMaxWidth }
        guard let geo else { return geo?.notchWidth ?? 0 }
        return leftWingWidth + geo.notchWidth + rightWingWidth
    }

    private var pillLeadingOffset: CGFloat {
        if isExpanded {
            // After the panel has snapped to fit the visible shape (post
            // open animation), the SwiftUI canvas is now 420 wide and
            // the pill must render at the leading edge — no offset.
            // During the open animation, panel is still 580 wide and
            // we offset by (580-420)/2 = 80 to center on the notch.
            if frameReporter.panelFitsVisibleShape { return 0 }
            return (geo.map { $0.leftWingWidth + $0.notchWidth + $0.rightWingWidth } ?? expandedMaxWidth) / 2 - expandedMaxWidth / 2
        }
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
                .frame(
                    width: frameReporter.panelFitsVisibleShape
                        ? expandedMaxWidth
                        : (geo.map { $0.leftWingWidth + $0.notchWidth + $0.rightWingWidth } ?? 580),
                    height: frameReporter.panelFitsVisibleShape
                        ? notchShapeHeight
                        : trackNotchWindowHeight
                )
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
                            NSLog("[TN.diag] hoverGate stage1 — exit dwell satisfied, awaiting fresh enter (baseline rebased to \(windowHoverState.stripEnterCount))")
                            hoverGateAwaitingExit = false
                            // Rebase baseline to whatever count is now. Only
                            // enters AFTER this point can satisfy the gate.
                            hoverGateBaseline = windowHoverState.stripEnterCount
                        }
                        hoverGateExitDwellWork = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.60, execute: work)
                        NSLog("[TN.diag] hoverGate exit dwell started (600ms)")
                    } else {
                        // shouldShow→true while gate is active.
                        // If isHovered, cursor came back (real or spurious) — block it.
                        // If NOT isHovered, the flip came from activeProviders (an LLM
                        // started consuming), which is cursor-independent — fall through
                        // and let the settle timer call expand() normally.
                        if isHovered {
                            if hoverGateExitDwellWork != nil {
                                hoverGateExitDwellWork?.cancel()
                                hoverGateExitDwellWork = nil
                                NSLog("[TN.diag] hoverGate exit dwell CANCELLED — cursor came back")
                            }
                            NSLog("[TN.diag] shouldShow→true IGNORED — still awaiting genuine cursor leave (count=\(windowHoverState.stripEnterCount) baseline=\(baseline))")
                            hoverSettleWork?.cancel()
                            hoverSettleWork = nil
                            return
                        }
                        NSLog("[TN.diag] shouldShow→true from activeProviders — bypassing hover gate, allowing expand")
                    }
                }
                if windowHoverState.stripEnterCount > baseline {
                    NSLog("[TN.diag] hoverGate cleared — fresh enter (count=\(windowHoverState.stripEnterCount) > baseline=\(baseline))")
                    hoverGateBaseline = nil
                    // Fall through and process this shouldShow change normally.
                } else {
                    NSLog("[TN.diag] shouldShow→\(show) IGNORED — awaiting fresh strip enter (count=\(windowHoverState.stripEnterCount) baseline=\(baseline))")
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
                        windowHoverState.isHovered = true
                        return
                    }
                }
                if want { expand() } else { collapse() }
            }
            hoverSettleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: work)
        }
        // When hover enters while the pill is already expanded (active provider
        // was showing), targetProviders switches from activeProviders →
        // connectedProviders. shouldShow doesn't change so expand() never fires.
        // Slide out any connected providers not yet in iconSlideState.
        .onChange(of: windowHoverState.isHovered) { hovered in
            guard hovered, pillExpanded, !isExpanded else { return }
            let missing = targetProviders.filter { iconSlideState[$0] == nil }
            NSLog("[TN.diag] hover entered while expanded — missing icons: \(missing.map(\.rawValue))")
            guard !missing.isEmpty else { return }
            for p in missing { iconSlideState[p] = false }
            // Refresh frozen counts AFTER seeding missing into iconSlideState
            // (so leftProviders/rightProviders already include the newcomers via
            // renderedProviders) but BEFORE the stagger fires. frozenLeft/RightCount
            // were set at expand() time with only the active provider count — without
            // this update the pill stays narrow and icons overflow the clipped wing.
            frozenLeftCount  = leftProviders.count
            frozenRightCount = rightProviders.count
            for (idx, p) in missing.enumerated() {
                let delay = Double(idx) * staggerStep
                let work = DispatchWorkItem { iconSlideState[p] = true }
                iconStaggerWorkItems.append(work)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }
        // When usageMap gains a new entry while pill is expanded (late data
        // arrival at startup or after reconnect), slide out the newcomer.
        .onChange(of: targetProviderSet) { _ in
            guard pillExpanded, !isExpanded else { return }
            let missing = targetProviders.filter { iconSlideState[$0] == nil }
            guard !missing.isEmpty else { return }
            NSLog("[TN.diag] targetProviderSet changed — missing icons: \(missing.map(\.rawValue))")
            for p in missing { iconSlideState[p] = false }
            for (idx, p) in missing.enumerated() {
                let delay = Double(idx) * staggerStep
                let work = DispatchWorkItem { iconSlideState[p] = true }
                iconStaggerWorkItems.append(work)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }
    }

    private func expand() {
        // No-op if expand is already in flight OR the pill is already out.
        if pillExpanded || expandIconsWork != nil { return }
        cancelPendingWork()
        let nonce = beginTransition()
        lastHoverExpandTimestamp = ProcessInfo.processInfo.systemUptime

        // Pre-register providers into iconSlideState at false so renderedProviders
        // is stable before the pill animates out.
        // On hover: pre-register ALL connected providers so connected-only icons
        // don't arrive late and shift wing width mid-animation.
        // Without hover (activeProviders path): only register active providers —
        // pre-registering all connected would cause every icon to slide out even
        // though the user hasn't hovered.
        if isHovered {
            let connected = registry.connectedProviders.filter { registry.usageMap[$0] != nil }
            for provider in connected { iconSlideState[provider] = false }
        } else {
            for provider in targetProviders { iconSlideState[provider] = false }
        }
        let allLeft  = leftProviders
        let allRight = rightProviders
        // Freeze wing counts so late usageMap arrivals don't animate pillWidth.
        frozenLeftCount  = allLeft.count
        frozenRightCount = allRight.count

        // Wing pill springs out.
        pillExpanded = false
        withAnimation(.interactiveSpring(response: 0.38, dampingFraction: 0.82, blendDuration: 0.1)) {
            pillExpanded = true
        }

        // After the pill begins to extend (iconExpandDelay = 0.12s),
        // stagger each icon's slide-out flip — innermost-first.
        //   Left wing layout: Spacer | idx0 ... idx(N-1). idx=N-1 is
        //   rightmost, closest to notch (innermost) → fires at delay 0.
        //   Right wing layout: idx0 ... idx(N-1) | Spacer. idx=0 is
        //   leftmost, closest to notch (innermost) → fires at delay 0.
        let kickoff = DispatchWorkItem {
            guard transitionNonce == nonce else { return }
            let leftCount = allLeft.count
            for (idx, provider) in allLeft.enumerated() {
                let delay = Double(leftCount - 1 - idx) * staggerStep
                let perIcon = DispatchWorkItem {
                    guard transitionNonce == nonce else { return }
                    iconSlideState[provider] = true
                }
                iconStaggerWorkItems.append(perIcon)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: perIcon)
            }
            for (idx, provider) in allRight.enumerated() {
                let delay = Double(idx) * staggerStep
                let perIcon = DispatchWorkItem {
                    guard transitionNonce == nonce else { return }
                    iconSlideState[provider] = true
                }
                iconStaggerWorkItems.append(perIcon)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: perIcon)
            }
        }
        expandIconsWork = kickoff
        DispatchQueue.main.asyncAfter(deadline: .now() + iconExpandDelay, execute: kickoff)
    }

    private func collapse() {
        // Idempotency guard.
        if !pillExpanded { return }
        cancelPendingWork()
        let nonce = beginTransition()

        // Per-icon staggered slide-back. Innermost retracts first.
        // `leftProviders`/`rightProviders` derive from `renderedProviders`
        // (a union of `targetProviders` and in-flight `iconSlideState`
        // entries) so icons stay in the view tree through the slide-back
        // even after `isHovered` flipped false and `targetProviders`
        // shrunk.
        let allLeft  = leftProviders
        let allRight = rightProviders
        NSLog("[TN.diag] collapse() scheduling slide-back for \(allLeft.count + allRight.count) icons")
        let leftCount = allLeft.count
        var maxDelay: Double = 0
        for (idx, provider) in allLeft.enumerated() {
            let delay = Double(leftCount - 1 - idx) * staggerStep
            maxDelay = max(maxDelay, delay)
            let perIcon = DispatchWorkItem {
                guard transitionNonce == nonce else { return }
                NSLog("[TN.diag] slide-back flip provider=\(provider.rawValue) → false")
                iconSlideState[provider] = false
            }
            iconStaggerWorkItems.append(perIcon)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: perIcon)
        }
        for (idx, provider) in allRight.enumerated() {
            let delay = Double(idx) * staggerStep
            maxDelay = max(maxDelay, delay)
            let perIcon = DispatchWorkItem {
                guard transitionNonce == nonce else { return }
                NSLog("[TN.diag] slide-back flip provider=\(provider.rawValue) → false")
                iconSlideState[provider] = false
            }
            iconStaggerWorkItems.append(perIcon)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: perIcon)
        }

        // After the staggered slide-back fully settles, shrink the pill.
        // Budget: longest stagger delay + per-icon spring settle
        // (~0.18s for response 0.20).
        let iconCollapseWindow: Double = maxDelay + 0.22
        let work = DispatchWorkItem {
            guard transitionNonce == nonce else { return }
            withAnimation(.interactiveSpring(response: 0.38, dampingFraction: 0.82, blendDuration: 0.1)) {
                pillExpanded = false
            }
            // Drop iconSlideState entries and frozen counts — pill is now
            // fully retracted, next expand gets a fresh snapshot.
            iconSlideState = [:]
            frozenLeftCount  = nil
            frozenRightCount = nil
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
                withAnimation(.interactiveSpring(response: 0.52, dampingFraction: 0.72, blendDuration: 0.1)) {
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
            withAnimation(.interactiveSpring(response: 0.52, dampingFraction: 0.72, blendDuration: 0.1)) {
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
        hoverGateBaseline = windowHoverState.stripEnterCount
        hoverGateAwaitingExit = true
        NSLog("[TN.diag] closeExpanded — hoverGateBaseline=\(windowHoverState.stripEnterCount) awaitingExit=true")
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
            withAnimation(.easeIn(duration: 0.28)) {
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
        // Cancel any in-flight per-icon stagger flips so a fresh
        // expand/collapse doesn't race the previous transition's
        // pending iconSlideState[provider] = X mutations.
        for w in iconStaggerWorkItems { w.cancel() }
        iconStaggerWorkItems.removeAll()
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
                .allowsHitTesting(false)
                .animation(
                    isExpanded
                        ? .interactiveSpring(response: 0.52, dampingFraction: 0.72, blendDuration: 0.1)
                        : .easeIn(duration: 0.28),
                    value: pillWidth
                )
                .animation(
                    isExpanded
                        ? .interactiveSpring(response: 0.52, dampingFraction: 0.72, blendDuration: 0.1)
                        : .easeIn(duration: 0.28),
                    value: notchShapeHeight
                )
                .animation(
                    isExpanded
                        ? .interactiveSpring(response: 0.52, dampingFraction: 0.72, blendDuration: 0.1)
                        : .easeIn(duration: 0.28),
                    value: isExpanded
                )

            // Wing icons (idle/hover state) — hidden while expanded
            // Always in tree while pill is expanded so child dissolve animations can play
            if pillExpanded && !isExpanded {
                wingContent(geo: geo)
                    .frame(width: pillWidth, height: pillHeight)
                    .allowsHitTesting(false)
            }

            // When expanded: edit (left) and settings (right) flanking the notch.
            if isExpanded {
                let wingRegionWidth = (pillWidth - geo.notchWidth) / 2
                let notchGutter: CGFloat = 12
                HStack(spacing: 0) {
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
                    .padding(.trailing, notchGutter + 6)
                    .frame(width: wingRegionWidth, height: pillHeight, alignment: .trailing)

                    Color.clear
                        .frame(width: geo.notchWidth, height: pillHeight)

                    Button("settings") {
                        ConnectionWindowController.shared.open()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .contentShape(Capsule())
                    .padding(.leading, notchGutter)
                    .frame(width: wingRegionWidth, height: pillHeight, alignment: .leading)
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
                                Color.clear
                                    .onAppear {
                                        expandedContentHeight = proxy.size.height
                                        frameReporter.dropdownContentHeight = proxy.size.height
                                    }
                                    .onChange(of: proxy.size.height) { h in
                                        expandedContentHeight = h
                                        frameReporter.dropdownContentHeight = h
                                    }
                            }
                        )
                }
                .frame(width: pillWidth)
                .clipped()
            }

            // Topmost layer: notch bar tap zone — above DropdownContent so taps
            // on the pill strip always close the dropdown. Must be last in ZStack
            // (highest layer) so it intercepts hits before DropdownContent's clipped
            // VStack (which otherwise intercepts the full notchShapeHeight area).
            if isExpanded {
                Color.white.opacity(0.001)
                    .frame(width: pillWidth, height: pillHeight)
                    .contentShape(Rectangle())
                    .onTapGesture { onToggleDropdown() }
                    .frame(width: pillWidth, height: notchShapeHeight, alignment: .top)
            }
        }
        .frame(width: pillWidth, height: notchShapeHeight, alignment: .top)
        .offset(x: pillLeadingOffset)
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
                    ForEach(Array(leftProviders.enumerated()), id: \.element) { _, provider in
                        if let usage = registry.usageMap[provider] {
                            NotchSlideIcon(
                                usage: usage,
                                direction: .right,
                                isSlid: iconSlideState[provider] ?? false
                            )
                            .id("left-\(provider.rawValue)")
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
                    ForEach(Array(rightProviders.enumerated()), id: \.element) { _, provider in
                        if let usage = registry.usageMap[provider] {
                            NotchSlideIcon(
                                usage: usage,
                                direction: .left,
                                isSlid: iconSlideState[provider] ?? false
                            )
                            .id("right-\(provider.rawValue)")
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

/// Pure-render icon. No internal state — the parent
/// (`NotchRootView.iconSlideState[provider]`) drives `isSlid`, and
/// SwiftUI's `.animation(value:)` modifier applies the spring on every
/// flip. This replaces the prior `.onChange(of: isShowing) +
/// DispatchQueue + withAnimation` pattern which failed to fire on
/// slide-back. Stagger timing is orchestrated by the parent's per-icon
/// dispatch — each provider's slide state flips on its own delay.
private struct NotchSlideIcon: View {
    let usage: ProviderUsage
    let direction: SlideDirection
    let isSlid: Bool
    private let slideDistance: CGFloat = 36

    private var hiddenOffset: CGFloat {
        direction == .right ? slideDistance : -slideDistance
    }

    var body: some View {
        let _ = NSLog("[TN.diag] NotchSlideIcon body provider=\(usage.provider.rawValue) isSlid=\(isSlid)")
        return WingIconView(usage: usage)
            .opacity(isSlid ? 1 : 0)
            .offset(x: isSlid ? 0 : hiddenOffset)
            .animation(
                .interactiveSpring(response: 0.20, dampingFraction: 0.82, blendDuration: 0.05),
                value: isSlid
            )
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
