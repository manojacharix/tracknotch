# TrackNotch — Testing Plan

Companion to `SHIP_READINESS.md`. Two layers: automated XCTest (Sonnet's job) + manual soak (your job before each release).

## 1. Automated tests (XCTest)

Seed files live in `TrackNotch/TrackNotchTests/`. Wiring instructions in `TrackNotchTests/README.md`.

### Already written
- `ProviderModelsTests` — formatters, thresholds, partitioning
- `BudgetManagerTests` — alert firing, reset semantics
- `ProviderRegistryLingerTests` — 4-second linger window
- `NotchWindowGeometryTests` — pill hit-rect math (the bug from 2026-04-29)
- `NotchModeDetectionTests` — display-mode flags

### To write next (in order)
1. **`URLProtocol` mock for fetchers.** Cover OpenAI cost endpoint (200/404/429), Anthropic usage, Claude rate-limit headers. Verify backoff doubles on 429 and resets on 200.
2. **Codable round-trips.** `BudgetConfig`, `LLMProvider`, `UsageWindow` — guard against silent JSON breakage.
3. **`ProviderAuthManager` Keychain.** Use a separate service identifier (`com.tracknotch.app.tests`) to avoid clobbering real keys; verify save → load → disconnect → load returns nil.
4. **`hoverRect` parameterised cases.** Negative-origin external (display to the left of primary), retina with 32pt menu bar, multiple icons. See TODO inside `NotchWindowGeometryTests.swift`.
5. **NotchMode decision helper.** Extract pure helper from `NotchMode.detect(for:)` per TODO in `NotchModeDetectionTests.swift`, then pin all four cases.

### CI
After the test target is wired, add `.github/workflows/test.yml` running:
```
xcodebuild -project TrackNotch/TrackNotch.xcodeproj \
           -scheme TrackNotch \
           -destination 'platform=macOS' \
           test
```

## 2. Manual soak test

Run before tagging any release. ~15 minutes. Mark each ✓ / ✗ in the release-notes PR.

### Cold launch
- [ ] Quit app fully. Launch fresh. Pill animates in within 1s.
- [ ] No `print` lines in Console.app filtered by subsystem `com.tracknotch.app` in the Release build (after P0 #3).
- [ ] No Gatekeeper warning on a Mac that has never seen the app (after P0 #4).

### Single display — hardware notch (notched MacBook)
- [ ] Hover over the right wing — wing expands.
- [ ] Click the notch — dropdown opens. Click outside — dropdown closes.
- [ ] Trigger usage in Claude Code (run any prompt) — pill icon goes active, lingers ~4s after the response.

### Single display — external (clamshell)
- [ ] Pill renders below the menu bar, centred. (This is the bug from 2026-04-29.)
- [ ] Hover *on* the pill — expands. Hover *above* the pill — does NOT expand.
- [ ] Click the pill — dropdown opens. Click outside — closes.

### Extended display (MacBook + external)
- [ ] Both displays show their own pill independently.
- [ ] Disconnect the external — its window cleans up; logs do not show "ghost" updates.
- [ ] Reconnect — pill returns within 1s.

### Sleep / wake
- [ ] Close the lid 30s, reopen. Hover still works.
- [ ] System sleep 60s, wake. Hover still works.

### Settings
- [ ] Open Settings, paste an OpenAI API key — pill switches to "connected" within 5s.
- [ ] Disconnect — pill disappears within 1s.
- [ ] Toggle "Launch at login" twice — no error in Console.

### Edge cases
- [ ] Connect 6 providers at once — wing/pill renders without overflow.
- [ ] Set budget threshold to 50% on a provider already at 60% — no instant alert (already crossed).
- [ ] Force-quit the app from Activity Monitor — relaunch is clean.

## 3. Reporting

Open a fresh GitHub issue per regression with:
- macOS version
- Display configuration
- Steps to reproduce
- Console.app log filter `subsystem:com.tracknotch.app` (last 1 min)
