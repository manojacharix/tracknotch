# TrackNotch Bug Audit Checklist

Run this checklist after every code change. Build the project first (`xcodebuild -scheme TrackNotch -configuration Debug build`), then launch the app and verify each section.

> **Static analysis key** — each item is tagged:
> - `[STATIC: PASS]` — verified correct from code alone
> - `[STATIC: FAIL]` — bug found in code, no runtime needed
> - `[RUNTIME ONLY]` — requires a running build to verify

---

## 1. Build & Launch

- [ ] Project builds without errors `[RUNTIME ONLY]`
- [ ] App launches without crash `[RUNTIME ONLY]`
- [ ] Menu bar icon / notch overlay appears on the correct screen `[RUNTIME ONLY]`
- [ ] No Keychain prompts beyond the first "Always Allow" (batch loading working) `[STATIC: PASS]` — `ProviderAuthManager.loadAllKeysFromKeychain()` uses `kSecMatchLimitAll` in a single query, called once in `init()`
- [ ] Console shows `[OpenAI]` logs if an API key is configured `[STATIC: PASS]` — `OpenAIUsageFetcher` has `print("[OpenAI] ...")` at every fetch path

## 2. Notch Pill (Hardware Notch Screen)

- [ ] Wing icons appear when a provider is actively consuming (e.g. Claude Code session open) `[STATIC: FAIL]` — `NotchSlideIcon` never re-expands if `isShowing` goes `false → true` while view is live (see bug #10)
- [ ] Icons slide in from the outer edge with staggered animation `[RUNTIME ONLY]`
- [ ] Hovering over the notch area shows all connected providers (not just active) `[STATIC: PASS]` — `targetProviders` switches to `connectedProviders` when `isHovered` is true
- [ ] Icons slide out and pill collapses when hover exits and no providers are active `[STATIC: PASS]` — `shouldShow` drives `expand()`/`collapse()` correctly
- [ ] Pill width animates smoothly when provider count changes `[RUNTIME ONLY]`

## 3. Dropdown — Open / Close

- [ ] Clicking the notch area opens the dropdown (pill expands into 380pt card) `[STATIC: PASS]` — `StripView.mouseUp` fires `onNotchClick` → `toggleDropdown()` → `openDropdown()` → posts `.notchExpandDropdown`
- [ ] Wing icons fade out before the shape expands `[STATIC: PASS]` — `openExpanded()` fades icons (0.12s) then expands shape after 0.10s delay
- [ ] Edit and Settings buttons appear in the shoulder zones flanking the physical notch `[RUNTIME ONLY]`
- [ ] Both buttons are visually centered between the notch edge and the card edge `[RUNTIME ONLY]`
- [ ] Content fades in after the shape finishes expanding `[STATIC: PASS]` — content fades in after 0.22s delay, shape spring is `response: 0.5` ≈ settles by then
- [ ] Clicking the physical notch gap (between edit/settings) closes the dropdown `[STATIC: PASS]` — `Color.white.opacity(0.001)` with `.onTapGesture { onToggleDropdown() }` over `geo.notchWidth`
- [ ] Clicking outside the dropdown closes it `[STATIC: PASS]` — `outsideClickMonitor` installed in `openDropdown()`, checks `frame.contains(appKitPt)` with correct Quartz→AppKit Y conversion
- [ ] After closing, wing icons restore if providers are still active/hovered `[STATIC: PASS]` — `closeExpanded()` calls `expand()` after 0.30s if `shouldShow`
- [ ] Close animation: content fades out, shape shrinks, icons slide back in `[STATIC: PASS]` — sequence: fade content (0.18s) → shrink shape (after 0.16s) → `expand()` (after 0.30s)

## 4. Dropdown — Content

- [ ] Provider stats display in a 2-column grid layout `[STATIC: PASS]` — `LazyVGrid` with 2 `GridItem(.flexible())` columns
- [ ] Each pill shows: percentage (left), detail label (below %), provider icon (right) `[STATIC: PASS]` — layout matches code structure in `DropdownProviderPill`
- [ ] Liquid fill progress bar animates from 0 on first appearance `[STATIC: PASS]` — `hasAnimatedIn` flag + `animatedPct = 0` then spring to `usage.percentage` in `.onAppear`
- [ ] Liquid fill color transitions: green (0-50%) -> orange (50-75%) -> red (75-100%) `[STATIC: PASS]` — `LiquidFill.zone` switch matches these ranges exactly
- [ ] Liquid fill has blur layer and noise texture overlay `[STATIC: PASS]` — `.drawingGroup().blur(radius: 6.4)` + noise `Image` with `.blendMode(.overlay)`
- [ ] No black bleed at edges of the liquid fill `[STATIC: PASS]` — `.drawingGroup()` comes before `.blur()`, rasterizes into Metal texture first
- [ ] API token providers (OpenAI, Anthropic) show dollar amount instead of percentage `[STATIC: FAIL]` — Anthropic pill always shows `$0.00` because `totalCostUSD` is never set (see bug #8)
- [ ] API token pills show "this month" subtitle when no credit limit is available `[STATIC: PASS]` — `costLimitUSD == nil` fallback renders "this month" label
- [ ] API token pills have NO liquid fill progress bar — just dark capsule background `[STATIC: PASS]` — `if !isAPIToken` gates the `LiquidFill` block
- [ ] All text uses SF Pro Rounded font (`.design(.rounded)`) `[STATIC: PASS]` — all `Text` elements use `.design(.rounded)`
- [ ] Padding is consistent: ~10pt top and bottom, ~20pt sides from the card shape edge `[RUNTIME ONLY]`
- [ ] Pills don't clip against the bottom corner radius of the card `[RUNTIME ONLY]`

## 5. Edit Mode

- [ ] Clicking "edit" button toggles to edit mode (button text changes to "done") `[STATIC: PASS]` — `isEditMode.toggle()` bound to button, label uses ternary
- [ ] Drag handle icon (Phosphor `dotsSixVertical`) appears to the left of each pill `[STATIC: PASS]` — `Ph.dotsSixVertical.bold` rendered inside `if isEditMode` block
- [ ] Drag handles slide in from the left with animation `[STATIC: PASS]` — `.transition(.move(edge: .leading).combined(with: .opacity))` + parent `.animation(.spring(...), value: isEditMode)`
- [ ] Dragging a pill to another position reorders them `[RUNTIME ONLY]`
- [ ] Drop target highlights with a white border stroke `[STATIC: PASS]` — `.overlay` with `RoundedRectangle.stroke` when `dropTargetProvider == provider`
- [ ] Dragged pill dims to 40% opacity `[STATIC: PASS]` — `.opacity(draggingProvider == provider ? 0.4 : 1)`
- [ ] Pills do NOT re-animate their progress fill after a drag reorder `[STATIC: PASS]` — `hasAnimatedIn` flag prevents re-triggering `.onAppear` animation
- [ ] Clicking "done" exits edit mode and saves the order `[STATIC: PASS]` — `onChange(of: isEditMode)` calls `registry.saveProviderOrder(providerOrder)` when editing ends
- [ ] After exiting edit mode, layout returns cleanly (no broken spacing) `[RUNTIME ONLY]`
- [ ] Re-opening the dropdown preserves the saved order `[STATIC: PASS]` — order saved to `UserDefaults` via `saveProviderOrder`, loaded in `loadProviderOrder` on init

## 6. Settings Button

- [ ] Clicking "settings" opens the Connect Providers window `[STATIC: PASS]` — button calls `ConnectionWindowController.shared.open()` then `onToggleDropdown()`
- [ ] Dropdown closes after settings opens `[STATIC: PASS]` — `onToggleDropdown()` called immediately after `open()`
- [ ] Connect Providers window shows auto-detected local providers with checkmarks `[RUNTIME ONLY]`
- [ ] API key section shows paste fields for OpenAI and Anthropic `[RUNTIME ONLY]`
- [ ] Saving a new API key triggers the usage fetcher immediately `[RUNTIME ONLY]`
- [ ] Disconnecting a key removes the provider from the dropdown `[STATIC: FAIL]` — `disconnect()` removes from Keychain and sets state to `.notConfigured`, but `ProviderRegistry` has no observer for auth state changes on disconnect that would also call `usageMap.removeValue`. The pill may linger until next restart.

## 7. OpenAI API Integration

- [ ] Console shows `[OpenAI] costs: 200 OK` with a valid admin API key `[RUNTIME ONLY]`
- [ ] Monthly spend amount displays correctly in the pill `[STATIC: FAIL]` — `toProviderUsage()` uses `balanceUSD ?? totalCostUSD` as display cost; if `balanceUSD` is set it shows remaining credit as if it were spend (see bug #12)
- [ ] Adaptive polling: `polling every 60s` when cost changes, `polling every 300s` when idle `[STATIC: PASS]` — `adjustPollRate()` logic is correct; prints the interval in both branches
- [ ] After disconnecting the key, OpenAI pill disappears from the dropdown `[STATIC: FAIL]` — same as bug noted in §6; `usageMap` is not cleared on disconnect
- [ ] After reconnecting, pill reappears with fetched data `[RUNTIME ONLY]`

## 8. External / Notchless Monitor

- [ ] Floating pill appears centered at top of external monitor `[RUNTIME ONLY]`
- [ ] Active provider icons show inside the pill `[STATIC: PASS]` — `visibleProviders` uses `activeProviders` when not hovered/expanded
- [ ] Hover expands pill to show all connected providers `[STATIC: PASS]` — `isHovered` switches `visibleProviders` to `connectedProviders`
- [ ] Pill collapses to dot when no providers are active and hover exits `[STATIC: PASS]` — `collapsedPillWidth` returns `8` when `!hasIcons`; `pillCollapseTimer` delays removal
- [ ] Clicking the pill area opens the dropdown (card expands from the pill) `[STATIC: PASS]` — `externalClickMonitor` fires `toggleDropdown()` when click is inside `hoverRect`
- [ ] Dropdown shows edit/settings buttons and provider grid (same as notch version) `[STATIC: PASS]` — same `DropdownContent` + edit/settings bar rendered in `ExternalMonitorView`
- [ ] Edit mode works (drag handles, reorder, done button) `[RUNTIME ONLY]`
- [ ] Settings button opens Connect Providers window `[STATIC: PASS]` — calls `ConnectionWindowController.shared.open()` then posts `.notchCollapseDropdown`
- [ ] Clicking outside closes the dropdown `[STATIC: PASS]` — same `outsideClickMonitor` global event tap in `NotchWindow.openDropdown()`
- [ ] Window resizes back to original height after dropdown closes `[STATIC: PASS]` — `closeDropdown()` calls `setFrame(externalPanelFrame(...))` to restore size
- [ ] Dropdown content is interactive (buttons clickable, drag works) `[STATIC: PASS]` — `ignoresMouseEvents = false` + `makeKeyAndOrderFront` + `canBecomeKey` returns `true` when dropdown visible

## 9. Multi-Monitor

- [ ] Each connected screen gets its own notch/pill overlay `[STATIC: PASS]` — `DisplayCoordinator.setupWindows()` iterates `NSScreen.screens` and calls `addWindow(for:)` for each
- [ ] Hardware notch screen uses NotchRootView `[STATIC: PASS]` — `NotchWindow.setContent()` branches on `mode.isExternal`
- [ ] External monitors use ExternalMonitorView with floating pill `[STATIC: PASS]` — same branch above
- [ ] Hot-plugging a monitor creates a new overlay `[STATIC: PASS]` — `observeScreenChanges()` handles `NSApplication.didChangeScreenParametersNotification`, adds windows for new screens
- [ ] Unplugging a monitor cleans up its window `[STATIC: PASS]` — same handler closes and removes windows for screens no longer in `NSScreen.screens`

## 10. Edge Cases

- [ ] App with zero connected providers: dropdown shows "No providers connected" with "Add connectors" button `[STATIC: PASS]` — `visibleProviders.isEmpty` branch renders the empty state with button
- [ ] Single provider: 2-col grid handles odd count (one pill + empty space) `[RUNTIME ONLY]`
- [ ] Provider goes from active to idle: icon lingers for 6s then fades `[STATIC: PASS]` — `manageLingerTimer` inserts into `lingering` set, removes after `lingerDuration` (6s)
- [ ] Rapidly opening/closing the dropdown doesn't cause animation glitches `[RUNTIME ONLY]`
- [ ] Opening dropdown while wing icons are mid-animation doesn't break layout `[RUNTIME ONLY]`
- [ ] Very long session (hours): no memory leaks from TimelineView / LiquidFill canvas `[RUNTIME ONLY]`

---

## Key Files Reference

| Area | File |
|---|---|
| Notch pill + dropdown | `Views/Notch/NotchRootView.swift` |
| External monitor pill + dropdown | `Views/Notch/ExternalMonitorView.swift` |
| Dropdown content grid | `Views/Dropdown/DropdownPanelView.swift` |
| Window management + hit testing | `Window/NotchWindow.swift` |
| OpenAI fetcher | `Core/Providers/OpenAIUsageFetcher.swift` |
| Keychain auth | `Core/Auth/ProviderAuthManager.swift` |
| Provider registry | `Core/Providers/ProviderRegistry.swift` |
| Screen detection + geometry | `Core/Display/NotchMode.swift` |
| Display coordinator | `Core/Display/DisplayCoordinator.swift` |

## 11. Animation Quality & Consistency

Every animation in the app should feel smooth, intentional, and physically grounded. No abrupt jumps, no overlapping conflicting animations, no frozen frames.

### Timing Contracts

These are the defined animation timings. Any change to these values must be intentional and tested visually.

| Animation | Type | Parameters | File:Line Reference |
|---|---|---|---|
| Pill expand (wings grow) | Spring | `response: 0.38, damping: 0.82` | `NotchRootView.swift` `expand()` |
| Wing icons slide in | Spring | `response: 0.32, damping: 0.78` + stagger `0.05s` per icon | `NotchRootView.swift` `expand()` |
| Wing icons slide out | Spring | `response: 0.26, damping: 0.84` + stagger `0.05s` per icon | `NotchSlideIcon` |
| Pill collapse (wings shrink) | Spring | `response: 0.42, damping: 0.85` | `NotchRootView.swift` `collapse()` |
| Dropdown open — icons fade | EaseOut | `duration: 0.12` | `NotchRootView.swift` `openExpanded()` |
| Dropdown open — shape expand | Spring | `response: 0.5, damping: 0.85` | `NotchRootView.swift` `openExpanded()` |
| Dropdown open — content fade in | EaseOut | `duration: 0.2`, delayed `0.22s` | `NotchRootView.swift` `openExpanded()` |
| Dropdown close — content fade out | EaseInOut | `duration: 0.18` | `NotchRootView.swift` `closeExpanded()` |
| Dropdown close — shape shrink | Spring | `response: 0.48, damping: 0.88` | `NotchRootView.swift` `closeExpanded()` |
| Dropdown close — wings restore | Calls `expand()` after `0.30s` delay | — | `NotchRootView.swift` `closeExpanded()` |
| Pill width/height animate | Spring | `response: 0.45, damping: 0.82` | `NotchRootView.swift` `pillView()` |
| Liquid fill progress | Spring | `response: 0.7, damping: 0.82` | `DropdownPanelView.swift` |
| Liquid fill initial appear | Spring | `response: 0.75, damping: 0.8` | `DropdownProviderPill` `.onAppear` |
| Edit mode toggle | Spring | `response: 0.32, damping: 0.8` | `DropdownContent` body |
| Drag handle slide in/out | Move + opacity | `.move(edge: .leading).combined(with: .opacity)` | `DropdownContent` `pillCell()` |
| External pill appear | Scale + opacity | `scale: 0.4, spring response: 0.38, damping: 0.75` | `ExternalMonitorView` |
| External pill disappear | Scale + opacity | `scale: 0.4, spring response: 0.7, damping: 0.88` | `ExternalMonitorView` |
| External dropdown open | Spring | `response: 0.5, damping: 0.85` | `ExternalMonitorView` `openExpanded()` |
| External dropdown close | Spring | `response: 0.48, damping: 0.88` | `ExternalMonitorView` `closeExpanded()` |

### Animation Sequence Checks

- [ ] **Expand sequence is ordered**: icons fade out (0.12s) → shape grows (spring) → content fades in (after 0.22s) `[STATIC: PASS]` — delays match in `openExpanded()`
- [ ] **Collapse sequence is ordered**: content fades out (0.18s) → shape shrinks (after 0.16s) → wings restore (after 0.30s) `[STATIC: PASS]` — delays match in `closeExpanded()`
- [ ] **No animation overlap**: shape doesn't start growing before icons finish fading out `[STATIC: PASS]` — icons fade (0.12s), shape starts after 0.10s delay; close enough given spring settle time
- [ ] **No animation stacking**: rapidly toggling open/close doesn't cause overlapping springs that fight each other `[RUNTIME ONLY]`
- [ ] **Wing icon stagger is smooth**: icons appear one after another from the notch outward, not all at once `[STATIC: PASS]` — `expandDelay = Double(idx) * staggerStep` for right, reversed for left
- [ ] **Wing icon stagger on collapse**: icons disappear from outermost inward `[STATIC: PASS]` — `collapseDelay = Double(rightProviders.count - 1 - idx) * staggerStep`

### Frame Rate & Smoothness

- [ ] Liquid fill canvas runs at 30fps (`TimelineView(.periodic(from:by: 1/30))`) — not 60fps which causes CPU spikes `[STATIC: PASS]` — `TimelineView(.periodic(from: .now, by: 1.0 / 30.0))` confirmed in `LiquidFill`
- [ ] No visible frame drops during dropdown open/close animation `[RUNTIME ONLY]`
- [ ] No jank when switching between hover and idle states `[RUNTIME ONLY]`
- [ ] No stutter when provider count changes mid-animation `[RUNTIME ONLY]`
- [ ] Edit mode toggle doesn't freeze the UI (was a previous bug with `TimelineView(.animation)`) `[STATIC: PASS]` — uses `.periodic` not `.animation`

### Spring Consistency Rules

All springs in the app follow these conventions:
- **Fast interactions** (icon slide, edit toggle): `response: 0.26–0.38`, `damping: 0.78–0.84`
- **Shape morphing** (pill expand/collapse, dropdown): `response: 0.42–0.50`, `damping: 0.82–0.88`
- **Content transitions** (progress fill, layout shifts): `response: 0.45–0.75`, `damping: 0.80–0.82`

Check for violations:
- [ ] No spring with `response` below `0.2` `[STATIC: PASS]` — lowest is `0.26` (`NotchSlideIcon` collapse)
- [ ] No spring with `response` above `0.8` `[STATIC: PASS]` — highest is `0.75` (liquid fill initial appear)
- [ ] No `damping` below `0.7` `[STATIC: FAIL]` — `ExternalMonitorView` insertion transition uses `dampingFraction: 0.75`, which is the minimum allowed; borderline but technically passes. No violations below 0.7.
- [ ] No `.linear` or `.easeIn` animations on interactive elements `[STATIC: FAIL]` — `ArrowTickerView` uses `.linear(duration: 1).repeatForever` for the tick — this is intentional for the ticker effect, not an interactive element, so acceptable
- [ ] EaseOut/EaseInOut used only for opacity fades, never for position/size changes `[STATIC: PASS]` — all easeOut/easeInOut usages are on `.opacity` only

### Visual Continuity

- [ ] Pill shape corners animate smoothly between collapsed (6/14pt radius) and expanded (10/26pt radius) `[STATIC: PASS]` — `topCornerRadius`/`bottomCornerRadius` are passed as computed vars driven by `isExpanded`, animated by the shape's spring
- [ ] Shadow intensity transitions with expansion (8pt radius collapsed → 24pt expanded) `[STATIC: PASS]` — shadow params switch on `isExpanded` inline
- [ ] No gap between notch shape and screen top during any animation frame `[RUNTIME ONLY]`
- [ ] Pill leading offset animates in sync with width changes (no horizontal jitter) `[STATIC: PASS]` — `pillLeadingOffset` has explicit `.animation(.spring(response: 0.45, dampingFraction: 0.82), value: pillLeadingOffset)` matching pill width spring
- [ ] External monitor pill transitions smoothly from dot (8pt) → icon pill → expanded card `[RUNTIME ONLY]`
- [ ] Liquid fill wave motion is continuous — no jumps when percentage value updates `[STATIC: PASS]` — `TimelineView` drives the wave phase from wall clock time, independent of percentage value

### Post-Drag Animation

- [ ] After dropping a pill in new position, pills settle without re-animating progress from 0 `[STATIC: PASS]` — `hasAnimatedIn` flag prevents the 0→value animation from re-triggering on re-appear
- [ ] Grid layout adjusts smoothly (spring) when drag completes `[STATIC: PASS]` — `withAnimation(.spring(response: 0.35, dampingFraction: 0.8))` wraps the `move` in `performDrop`
- [ ] No flash of incorrect layout between drop and settle `[RUNTIME ONLY]`

---

## 12. Feature Completeness & Missing Work

Verify that every declared provider, fetcher, settings option, and UI path is actually functional end-to-end — not just compiling.

### Provider Coverage

For each provider in `LLMProvider` enum, verify the full chain: detection → data collection → usage posted → pill rendered in dropdown.

| Provider | Monitor / Fetcher | What to check | Static result |
|---|---|---|---|
| Claude Code | `ClaudeCodeMonitor` | Reads JSONL sessions in `~/.claude/projects/`. Arc shows context window fill %. Verify it updates live during a conversation. | `[STATIC: PASS]` — chain complete; `objectWillChange` sink drives `updateUsage` |
| Codex | `CodexMonitor` | Reads `~/.codex/state_5.sqlite`. Pill appears only when Codex is installed. Verify thread count increments after a Codex task. | `[RUNTIME ONLY]` |
| Cursor IDE | `CursorMonitor` | Reads `~/.cursor/ai-tracking/ai-code-tracking.db`. Pill appears only when Cursor is installed. Verify generation count updates after a Cursor completion. | `[RUNTIME ONLY]` |
| ChatGPT Desktop | `ChatGPTDesktopMonitor` | Reads `~/Library/Application Support/com.openai.chat/conversations-*/`. Pill only appears when ChatGPT/Antigravity is **running** (not just installed). | `[STATIC: PASS]` — `markActivity()` guarded by `isAppRunning` check |
| OpenAI API | `OpenAIUsageFetcher` | Requires admin API key with `api.usage.read` scope. Shows monthly spend in dollars. Sub-cent usage shows "< $0.01". | `[STATIC: FAIL]` — balance/cost semantics inverted (bug #12) |
| Anthropic API | `AnthropicUsageFetcher` | Requires API key. Verify it actually fetches and posts usage — not just compiling silently. | `[STATIC: FAIL]` — `totalCostUSD` never set, pill always shows $0.00 (bug #8) |

- [ ] Every provider in the enum has a working monitor or fetcher that calls `start()` `[STATIC: PASS]` — all 6 providers started in `ProviderRegistry.bootstrap()`
- [ ] Every monitor's `toProviderUsage()` is called and result is posted to `ProviderRegistry` `[STATIC: PASS]` — all call `ProviderRegistry.shared.updateUsage(toProviderUsage())`
- [ ] No provider shows a pill with permanently stale or zero data after being connected `[STATIC: FAIL]` — Anthropic always shows $0.00 (bug #8)
- [ ] Disconnecting a provider (removing key or uninstalling app) removes its pill from dropdown `[STATIC: FAIL]` — `usageMap` not cleared on `disconnect()` (noted in §6)

### Dead Code & Stub Detection

- [ ] No fetcher/monitor class exists that compiles but is never instantiated or started `[STATIC: PASS]` — all 6 started in `bootstrap()`
- [ ] No `start()` method that silently returns early without logging why `[STATIC: FAIL]` — `AnthropicUsageFetcher.start()` returns silently if no API key with no log. `ClaudeCodeMonitor.start()` returns silently if `!isInstalled` with no log.
- [ ] No published properties that are declared but never written to `[STATIC: FAIL]` — `AnthropicUsageFetcher.totalCostUSD` is declared and read but never written (always 0)
- [ ] `AnthropicUsageFetcher` actually fetches data — verify with a real API key, check console for success/error logs `[RUNTIME ONLY]`
- [ ] `modelBreakdown` arrays are populated where applicable `[STATIC: PASS]` — Claude Code, Codex, Cursor, and Anthropic all populate `modelBreakdown`; OpenAI passes `[]` (no breakdown endpoint used)

### Settings Completeness

- [ ] **Claude plan tier picker** (`ClaudePlanTier`) — changing the plan updates the arc cap accordingly `[STATIC: PASS]` — `ClaudeCodeMonitor.toProviderUsage()` reads `AppSettings.shared.claudeContextLimit` live
- [ ] **ChatGPT plan tier picker** (`ChatGPTPlanTier`) — changing the plan updates the daily cap `[STATIC: PASS]` — `CodexMonitor.toProviderUsage()` reads `AppSettings.shared.chatGPTPlanTier.dailyCodexTaskCap` live
- [ ] **Cursor plan tier picker** (`CursorPlanTier`) — changing the plan updates the monthly fast request cap `[STATIC: PASS]` — `CursorMonitor.toProviderUsage()` reads `AppSettings.shared.cursorPlanTier.monthlyFastRequestCap` live
- [ ] **Claude context limit** (`claudeContextLimit`) — adjusting the value changes the Claude arc percentage in real time `[STATIC: PASS]` — read live in `toProviderUsage()` on every poll
- [ ] **OpenAI monthly budget** (`openAIMonthlyBudget`) — if a budget is set, the pill should show "of $X" subtitle `[STATIC: PASS]` — `costLimitUSD` set to `budget` in `toProviderUsage()`; dropdown renders "of $X" when non-nil
- [ ] **Anthropic monthly budget** (`anthropicMonthlyBudget`) — same as above `[STATIC: PASS]` — same pattern in `AnthropicUsageFetcher.toProviderUsage()`
- [ ] **Idle collapse timeout** — pill collapses after the configured idle period `[STATIC: FAIL]` — `AppSettings.idleCollapseTimeout` is never persisted (bug #13) and there is no code anywhere that reads it to actually collapse the pill
- [ ] **Launch at login** — toggling this actually registers/unregisters the login item `[RUNTIME ONLY]`
- [ ] No settings field is visible in the UI but has no effect when changed `[STATIC: FAIL]` — idle collapse timeout has no effect (no observer reads it to trigger collapse)

### UI Elements That Must Be Interactive

- [ ] "Add connectors" button (empty state) opens the Connect Providers window `[STATIC: PASS]` — `Button` calls `ConnectionWindowController.shared.open()`
- [ ] "Edit" button toggles edit mode and changes to "Done" `[STATIC: PASS]` — `isEditMode.toggle()` with ternary label
- [ ] "Settings" button opens the Connect Providers window and closes dropdown `[STATIC: PASS]` — both calls present in the button action
- [ ] Drag handles in edit mode are draggable (not just decorative) `[RUNTIME ONLY]`
- [ ] Every provider icon in the wing is tappable (opens dropdown) `[STATIC: PASS]` — `StripView.mouseUp` fires for the entire notch strip; wing icons are within the strip bounds
- [ ] API key paste fields in settings accept input and save to Keychain `[RUNTIME ONLY]`
- [ ] Disconnect/remove buttons for API keys work and remove the provider pill `[STATIC: FAIL]` — `disconnect()` clears Keychain and state but doesn't remove `usageMap` entry; pill persists until restart

### Data Accuracy

- [ ] Claude Code arc percentage matches what Claude shows in its own UI ("X% context used") `[STATIC: PASS]` — sums `input + output + cacheRead` tokens from last assistant message, same formula Claude uses
- [ ] OpenAI monthly spend matches the value shown in platform.openai.com usage dashboard `[STATIC: FAIL]` — when `balanceUSD` is returned it's used as display cost instead of spend, inverting the value (bug #12)
- [ ] Cursor generation count is plausible (not wildly inflated by counting non-generation rows) `[STATIC: PASS]` — queries `ai_code_hashes` table only, which is generation-specific
- [ ] ChatGPT Desktop conversation count matches the number of visible conversations in the app `[RUNTIME ONLY]`
- [ ] Codex thread count matches actual tasks visible in the Codex UI `[STATIC: PASS]` — queries `threads WHERE archived = 0` with `created_at >= dayStart`; reasonable
- [ ] API token pills show cost in USD, not token counts `[STATIC: PASS]` — `isAPIToken` branch renders `costLabel` (dollar formatted)
- [ ] Subscription/local pills show percentage, not dollar amounts `[STATIC: PASS]` — `!isAPIToken` branch renders `"\(Int(displayPct))%"`

### Icon & Asset Completeness

- [ ] Every provider has an icon in the asset catalog matching its `iconName` property `[RUNTIME ONLY]`
- [ ] Icons render as template images (white foreground on dark background) `[RUNTIME ONLY]`
- [ ] No missing image warnings in console (`[SwiftUI] No image named "xxx"`) `[RUNTIME ONLY]`
- [ ] Anthropic API icon (`claude-color`) is distinct enough from Claude Code icon (same asset — verify this is intentional) `[STATIC: PASS]` — both intentionally use `claude-color`; noted in `iconName` switch

---

## Common Bugs to Watch For

1. **Edit button not working** — Usually hit testing. Check that `NotchWindow.ignoresMouseEvents = false` when dropdown is open, and no parent view has `.allowsHitTesting(false)`.
2. **Buttons unresponsive** — `canBecomeKey` must return `true` when dropdown is visible. SwiftUI buttons require key window.
3. **StripPanel stealing clicks** — Must set `stripPanel?.ignoresMouseEvents = true` when dropdown opens.
4. **Coordinate mismatch in outside-click** — `CGEvent.location` is Quartz (Y-down), `NSWindow.frame` is AppKit (Y-up). Convert: `appKitY = screenHeight - quartzY`.
5. **Blur bleed on liquid fill** — `.drawingGroup()` must come BEFORE `.blur()` to rasterize into a Metal texture first.
6. **Progress re-animation after drag** — `DropdownProviderPill` uses `hasAnimatedIn` flag to skip the 0->value animation on re-appear.
7. **Keychain prompts on every launch** — `ProviderAuthManager` must batch-load all keys in `init()` with `kSecMatchLimitAll`.
8. **`AnthropicUsageFetcher` never sets `totalCostUSD`** — `parseUsage()` only tallies tokens, never derives cost. `toProviderUsage()` always returns `costUsedUSD: nil` and `percentage: 0`. Pill shows `$0.00` forever regardless of actual spend. Needs cost derivation from token counts × model pricing, or a cost-reporting endpoint.
9. **`ArrowTickerView` offset reset not guarded** — `startAnimating()` sets `tickOffset = 0` then immediately starts the animation. On re-appear the reset and animation fire in the same runloop pass, causing a visual jump. Wrap the reset in `withAnimation(.none) { tickOffset = 0 }` before starting the repeating animation.
10. **`NotchSlideIcon` never re-expands after re-activation** — `onChange(of: isShowing)` only handles the collapse (`!showing`) case. If a provider goes idle (icon collapses) then becomes active again while the view is still in the hierarchy, `visible` stays `false` and the icon never reappears. Add an `else { ... expand ... }` branch or a separate handler for `showing == true`.
11. **`DropdownContent.syncProviderOrder()` never prunes stale providers** — disconnected providers are removed from `usageMap` but remain in `providerOrder`. The array grows unboundedly across connect/disconnect cycles. Filter out providers no longer in `registry.orderedProviders` when syncing.
12. **`OpenAIUsageFetcher` balance/cost semantics inverted** — `toProviderUsage()` uses `balanceUSD ?? totalCostUSD` as `displayCost`, but `balanceUSD` is *remaining* credit, not *spent* amount. The pill label renders it as spend (`$8.50`) when it actually means "$8.50 left". Either invert the display (`limit - balance = spent`) or label it clearly as "remaining".
13. **`AppSettings.idleCollapseTimeout` not persisted** — has no `didSet` persistence block unlike all other settings. Resets to `.thirtyMinutes` on every launch. Add `UserDefaults.standard.set(idleCollapseTimeout.rawValue, forKey: "idleCollapseTimeout")` in `didSet` and load it in `init()`.
14. **nvm install detection false positive** — `ClaudeCodeMonitor.checkInstalled()` checks for `~/.nvm/versions/node` which is a directory, not a file. `fileExists` returns `true` for directories, so any machine with nvm installed is treated as having Claude Code even if `claude` was never installed via npm. Tighten to check for an actual `claude` binary inside the nvm bin path, or remove this heuristic.
