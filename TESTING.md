# TrackNotch — Test Plan

Comprehensive manual + automated test plan covering functionality, UI, integration, performance, security.

Legend: `[ ]` not run · `[P]` pass · `[F]` fail · `[N/A]` not applicable to hardware.

---

## 0. Test Environment Matrix

Run full suite against each row. Minimum: one notched Mac + one notchless Mac.

| # | Hardware | macOS | Display setup |
|---|----------|-------|---------------|
| E1 | MacBook Pro 14"/16" (notched) | 14.x | Built-in only |
| E2 | MacBook Pro 14"/16" (notched) | 15.x | Built-in + 1 external |
| E3 | MacBook Air M2 (notched) | 14.x | Built-in + 2 externals |
| E4 | MacBook Pro 13" (notchless) | 13.x | Built-in only |
| E5 | Mac mini / Studio (no built-in) | 14.x | 1 external |
| E6 | Any Mac | 14.x | Clamshell mode (lid closed, external only) |

Pre-flight per env: clean install, no Keychain entries, fresh `UserDefaults` (`defaults delete com.tracknotch.TrackNotch`).

---

## 1. Build & Launch

| ID | Step | Expected |
|----|------|----------|
| B1 | `xcodebuild -project TrackNotch.xcodeproj -scheme TrackNotch build` | Builds clean. No warnings re: deprecated APIs. |
| B2 | Run unit tests `xcodebuild test -scheme TrackNotch` | All `TrackNotchTests` pass. |
| B3 | Launch app fresh | No crash. Menubar icon appears. Notch pill renders on built-in display. |
| B4 | Quit + relaunch | Settings, provider order, Keychain entries persist. |
| B5 | Launch on Mac with no Internet | App launches. API providers show offline state, not crash. |
| B6 | Launch on locked screen / before login | If launch-at-login on, app waits for user session, no crash. |

---

## 2. Display Modes — `DisplayCoordinator` + `NotchMode`

### 2.1 Hardware notch (E1, E2, E3)

| ID | Step | Expected |
|----|------|----------|
| D1 | Boot app on notched MBP | Pill aligned to physical notch cutout (no gap, no overlap). |
| D2 | Hover physical notch area | Pill expands. Wing icons slide left + right symmetrically. |
| D3 | Toggle dark/light menu bar | Pill blends with menu bar. No seam visible. |
| D4 | Auto-hide menu bar on/off | Pill repositions correctly when menu bar appears/disappears. |

### 2.2 Software notch / notchless (E4, E5)

| ID | Step | Expected |
|----|------|----------|
| D5 | Launch on notchless Mac | Floating pill at top-center of main display. |
| D6 | Drag windows under it | Pill stays above all windows (window level correct). |
| D7 | Fullscreen an app | Pill hides or stays per design (verify against spec). |

### 2.3 External monitors (E2, E3, E5, E6)

| ID | Step | Expected |
|----|------|----------|
| D8 | Connect external while running | New window appears centered top of external within 1s. |
| D9 | Disconnect external | External window torn down cleanly. No orphan window, no crash, no zombie process. |
| D10 | Sleep Mac → wake | Windows restored on all displays. No duplicates. |
| D11 | Change display arrangement in Settings → Displays | `DisplayCoordinator` debounces, ends with 1 window per screen. |
| D12 | Mirror displays | Single pill, no duplicates on mirror. |
| D13 | Clamshell mode (E6) | Pill renders only on external. |
| D14 | Hot-plug 5x rapid connect/disconnect | Debounce holds. No leaks (verify with Instruments). |

---

## 3. Pill UI — `NotchRootView` + `NotchShape` + `NotchGlowBorder`

| ID | Scenario | Expected |
|----|----------|----------|
| P1 | Idle, no providers connected | Bare notch shape. No wings. No glow. |
| P2 | Idle, providers connected, none active | Bare notch. Hover reveals wings. |
| P3 | One provider becomes active | Pill expands. That provider's icon slides into wing. Springy animation. |
| P4 | Provider goes idle | After 4s linger timer, icon retracts. Ease-in close. |
| P5 | Hover idle pill | All connected providers' icons appear, staggered. |
| P6 | Mouse leave | Wings retract in reverse stagger. |
| P7 | Click pill | Dropdown panel opens (see §5). |
| P8 | Click again / outside | Dropdown closes. |
| P9 | Multiple providers active simultaneously | All icons visible in wings. Order matches user-set order. |
| P10 | Glow border | Pulses subtle when any provider active. Off when idle. |
| P11 | Notch shape clipping | Round corners match real notch radius on hardware notch Macs. |

### 3.1 Wing icons — `ProviderIconView` + `ArrowTickerView`

| ID | Scenario | Expected |
|----|----------|----------|
| W1 | Subscription provider, quota <60% | Green arc around icon. |
| W2 | Subscription provider, 60–85% | Orange arc. |
| W3 | Subscription provider, >85% | Red arc. |
| W4 | Subscription provider, depleted (100%) | Red arc pulses. |
| W5 | API provider actively spending | Upward arrow ticker animates. |
| W6 | API provider idle | Static icon, no arrow. |
| W7 | Arc transitions | Color crossfades smoothly, not a jump. |
| W8 | Pulse perf | 60fps maintained (Instruments → Animation Hitches). |

---

## 4. Providers — Functionality

For each provider: connection, refresh, error, disconnect, re-connect.

### 4.1 Claude Code (`ClaudeCodeMonitor`)

| ID | Step | Expected |
|----|------|----------|
| CC1 | Fresh install, no `~/.claude/projects/` | Provider shows "not connected" or zero-state. |
| CC2 | Run `claude` CLI, generate `.jsonl` activity | Monitor picks up file mod date within poll window. |
| CC3 | Active session | Wing icon shows. Context arc reflects session token count. |
| CC4 | OAuth token (`sk-ant-oat01-…`) entered in Settings | Real 5h + 7d rate-limit data fetched via `ClaudeRateLimitFetcher`. |
| CC5 | Token revoked / expired | Falls back to local-file estimate. Surfaces auth error in Settings. |
| CC6 | Plan tier = Free, Pro, Max5x, Max20x, Team | Token caps switch correctly. % usage recomputes. |
| CC7 | 5h window resets | Counter resets at window boundary. Budget alert clears. |
| CC8 | 7d window resets | Same. |
| CC9 | Two cards in dropdown | Both 5h and 7d cards render, distinct timers. |
| CC10 | Anthropic API key also active | Subscription icon hidden in wings (only API icon shows). |
| CC11 | Context window setting = 200K vs 1M | Arc recalibrates accordingly. |
| CC12 | Corrupt `.jsonl` file | Monitor logs error via `TNLog`, skips file, no crash. |
| CC13 | Symlinked projects dir | Followed correctly. |
| CC14 | Very large projects dir (1000+ files) | Scan completes <2s. CPU <5% steady-state. |

### 4.2 Anthropic API (`AnthropicUsageFetcher`)

| ID | Step | Expected |
|----|------|----------|
| AN1 | Enter valid key in Settings | Stored in Keychain (verify via `security` CLI). Status → connected. |
| AN2 | Invalid key | Error surfaced in Settings UI. No crash. |
| AN3 | Network down | Backoff + retry. UI shows last-known data with "stale" indicator. |
| AN4 | Spend incurred | Wing arrow ticker animates. Dropdown card updates cost. |
| AN5 | Monthly budget cap exceeded | `BudgetManager` fires alert. Wing icon turns red. |
| AN6 | Month rollover | Counter resets. Alert clears. |
| AN7 | Disconnect (remove key) | Provider hidden. Keychain entry removed. |

### 4.3 OpenAI API (`OpenAIUsageFetcher`)

Repeat AN1–AN7 with OpenAI key.

| ID | Extra | Expected |
|----|-------|----------|
| OA1 | Org-scoped vs project-scoped key | Both work. |
| OA2 | Rate-limited by OpenAI (429) | Honors `Retry-After`. No flood. |

### 4.4 Cursor (`CursorMonitor`)

| ID | Step | Expected |
|----|------|----------|
| CU1 | Cursor not installed | Provider hidden / "not detected". |
| CU2 | Cursor installed, signed in | Local data files read. Usage % shown. |
| CU3 | Cursor signed out | Connection state reflects. |
| CU4 | Cursor data file locked / in use | Reads succeed (no exclusive lock). |

### 4.5 Codex (`CodexMonitor`)

| ID | Step | Expected |
|----|------|----------|
| CX1 | No Codex sessions | Zero state. |
| CX2 | Active Codex session | File mod-date triggers active state. |
| CX3 | Old session files | Ignored beyond retention window. |

### 4.6 ChatGPT Desktop (`ChatGPTDesktopMonitor`)

| ID | Step | Expected |
|----|------|----------|
| CG1 | App not installed | Hidden. |
| CG2 | App running, conversation active | Active state. |
| CG3 | App quits | Returns to idle within 4s linger. |

### 4.7 Antigravity (`AntigravityMonitor`)

| ID | Step | Expected |
|----|------|----------|
| AG1 | Local file activity | Reflected within poll window. |
| AG2 | No activity | Idle. |

---

## 5. Dropdown Panel — `DropdownPanelView`

| ID | Scenario | Expected |
|----|----------|----------|
| DP1 | Open with no providers | Empty state with "Add connectors" CTA → opens Settings. |
| DP2 | Open with N providers | 2-column grid. All cards visible without scroll up to 6 cards; scrolls beyond. |
| DP3 | Card content | Usage %, cost or tokens, reset timer countdown, model breakdown all populated. |
| DP4 | Reset timer | Counts down in real time. Updates without panel close. |
| DP5 | Drag card to reorder | Other cards shift. Order persists across app restart (`AppSettings`). |
| DP6 | Edit mode toggle | Reveals reorder affordance + remove buttons. |
| DP7 | Claude Code secondary card slot | 5h and 7d cards both shown, labeled distinctly. |
| DP8 | Provider with stale data | "Last updated X ago" indicator. |
| DP9 | Click card | (Per spec) opens provider detail or stays. Verify no crash. |
| DP10 | Panel positioning | Anchored under pill, doesn't go off-screen on small displays. |
| DP11 | Panel on external display | Renders on the display where pill was clicked. |
| DP12 | Dark mode / light mode | Both render correctly. Contrast WCAG AA. |
| DP13 | Dynamic Type | Layout doesn't break at largest accessibility size. |

---

## 6. Settings — `SettingsView` + `ProviderConnectionView`

| ID | Scenario | Expected |
|----|----------|----------|
| S1 | Open Settings | Window appears. All sections render. |
| S2 | Toggle "Launch at Login" on | `SMAppService` registers. Verify with `launchctl list \| grep tracknotch`. |
| S3 | Toggle off | Service deregistered. |
| S4 | Toggle "Notch pill" off | Pill hides on all displays. Menubar icon stays. |
| S5 | Toggle back on | Pill returns. |
| S6 | Enter API key | Stored in Keychain. Field shows masked (•••). |
| S7 | Reveal/hide key | Toggle works. |
| S8 | Remove key | Keychain entry deleted. |
| S9 | Enter Claude OAuth token | Validated. Stored in Keychain. |
| S10 | Plan tier picker | All tiers selectable. Persists. |
| S11 | Context window picker (200K/1M) | Persists. Affects arc. |
| S12 | Drag-to-reorder providers | Order persists. Reflects in wings + dropdown. |
| S13 | Set monthly budget cap | Saved. Triggers alerts when crossed (§7). |
| S14 | Settings while pill open | No layout glitch. |
| S15 | Close + reopen Settings | All values retained. |

---

## 7. Budgets & Alerts — `BudgetManager` (`BudgetModels`)

| ID | Step | Expected |
|----|------|----------|
| BU1 | Cap = $10, spend $5 | No alert. |
| BU2 | Cross 80% threshold | Warning alert (if implemented). |
| BU3 | Cross 100% | Hard alert. Wing icon red, pulsing. |
| BU4 | Window resets (month) | Alert state clears. |
| BU5 | Cap = 0 / disabled | No alerts ever. |
| BU6 | Multiple providers, both over budget | Independent alerts. Don't conflate. |
| BU7 | Alert dismissed | Doesn't re-fire same window. Re-fires next window if still over. |

---

## 8. Auth & Security — `ProviderAuthManager`

| ID | Step | Expected |
|----|------|----------|
| SE1 | Enter key in Settings | `security find-generic-password -s tracknotch …` returns entry. |
| SE2 | Inspect app sandbox | Unsandboxed (entitlements verified). |
| SE3 | Search disk for plaintext key | `grep -r "sk-" ~/Library/Application\ Support/TrackNotch` → no hits. |
| SE4 | Search `UserDefaults` plist | No keys present. `defaults read com.tracknotch.TrackNotch` clean. |
| SE5 | Network sniff (Little Snitch / Charles) | Traffic only to `api.anthropic.com`, `api.openai.com`. No analytics, no telemetry domains. |
| SE6 | Force-quit during key write | Keychain consistent on relaunch. No partial entry. |
| SE7 | Keychain locked | Graceful prompt. No crash. |
| SE8 | Multiple Mac users | Keys scoped per-user, not shared. |

---

## 9. ProviderRegistry State Machine

| ID | Scenario | Expected |
|----|----------|----------|
| PR1 | Provider becomes active | `activeProviders` contains it. Observers fire once. |
| PR2 | Provider goes idle | Stays in `activeProviders` for 4s linger, then removed. |
| PR3 | Provider becomes active again during linger | Linger cancelled. Stays active. |
| PR4 | `connectionStates` updates | Published change reaches all observers. |
| PR5 | `usageMap` updates | Same. |
| PR6 | Race: two monitors update simultaneously | Thread-safe. No crash. Final state correct. |
| PR7 | Connect provider | `connectedProviders` updates. |
| PR8 | Disconnect provider | Removed from `connectedProviders`, `activeProviders`, `usageMap`. |

---

## 10. Performance & Resource Use

| ID | Test | Expected |
|----|------|----------|
| PE1 | Idle CPU (no providers active, 1 hr) | <0.5% sustained. |
| PE2 | All providers connected, idle | <2% sustained. |
| PE3 | All providers active | <5% sustained. |
| PE4 | RAM after 24 hr | No growth >50MB above baseline (leak check). |
| PE5 | File-handle count | Stable. Verify `lsof -p $(pgrep TrackNotch)` doesn't grow. |
| PE6 | Animation FPS during pill expand | 60fps. |
| PE7 | Energy Impact in Activity Monitor | "Low". |
| PE8 | Wake from sleep cost | Resume <1s. |

---

## 11. Logging — `TNLog`

| ID | Step | Expected |
|----|------|----------|
| L1 | Trigger error in monitor | Logged with category. Visible in Console.app filtered by subsystem. |
| L2 | Verbose off (release build) | No PII / keys logged. |
| L3 | Crash | Crash report generated under `~/Library/Logs/DiagnosticReports/`. |

---

## 12. Edge Cases & Regression

| ID | Scenario | Expected |
|----|----------|----------|
| EC1 | System time changes (DST, manual shift back) | Reset timers don't go negative or hang. |
| EC2 | Disk full | Monitors degrade gracefully. |
| EC3 | `~/.claude` permission denied | Logged, provider shows error state. |
| EC4 | Locale = RTL (Arabic) | Wings still slide correct direction (or mirrored per spec). |
| EC5 | Locale numbers (e.g. de-DE comma) | Cost formatted per locale. |
| EC6 | Very long model name | Truncates with ellipsis in card. |
| EC7 | Provider returns NaN/inf usage | Clamped, no UI break. |
| EC8 | Network flaps | Backoff doesn't hammer API. |
| EC9 | Two app instances launched | Second exits cleanly or activates first. |
| EC10 | Update from prior version | Settings/Keychain migrate. No data loss. |

---

## 13. Accessibility

| ID | Test | Expected |
|----|------|----------|
| A1 | VoiceOver on pill | Announces "TrackNotch, [provider] active, X% used". |
| A2 | VoiceOver on dropdown cards | Each card readable. |
| A3 | Keyboard nav into Settings | Full tab order. |
| A4 | Reduce Motion on | Springy anims swap to fades. |
| A5 | Increase Contrast | Arc colors remain distinguishable. |
| A6 | Color-blind sim (deuter/proton) | Green/orange/red arcs still distinguishable (shape or intensity differ). |

---

## 14. Uninstall

| ID | Step | Expected |
|----|------|----------|
| UN1 | Quit app, drag to Trash | App gone. |
| UN2 | Check Keychain | TrackNotch entries optionally retained or removed per design. Document either way. |
| UN3 | Check `~/Library/Application Support/TrackNotch` | Removable manually. No background daemon left. |
| UN4 | Check `launchctl list` | No tracknotch service if launch-at-login was off, or correctly removed if on + uninstalled. |

---

## 15. Automated Test Coverage Targets — `TrackNotchTests`

Add/verify unit tests for:

- `ProviderRegistry`: state transitions, linger timer, thread safety.
- `BudgetManager`: threshold logic, window reset, multi-provider isolation.
- `ProviderAuthManager`: Keychain CRUD, key validation.
- `AppSettings`: persistence round-trips, default values.
- `ClaudeCodeMonitor`: token-scan parser fixtures (sample `.jsonl`).
- `AnthropicUsageFetcher` / `OpenAIUsageFetcher`: response parsing, error mapping (mock `URLProtocol`).
- `ClaudeRateLimitFetcher`: 5h/7d window math, reset boundaries.
- `DisplayCoordinator`: screen add/remove debounce (inject mock `NSScreen` provider).
- `NotchMode`: hardware-vs-software detection.

Coverage goal: ≥70% lines on `Core/`. UI views excluded.

---

## 16. Sign-off Checklist

- [ ] All §1–§14 scenarios run on E1, E4, E5 minimum.
- [ ] §15 unit tests green in CI.
- [ ] §10 perf budgets met.
- [ ] §8 security audit clean.
- [ ] Crash-free over 48 hr soak across 2 machines.
- [ ] Release notes list any known-fail rows.
