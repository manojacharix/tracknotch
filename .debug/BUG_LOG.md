# TrackNotch Debug Bug Log
**Session start:** 2026-05-19  
**Build:** Debug (latest source, v1.0.4 build 5)  
**Goal:** Catalogue all issues for 0.5 stability milestone — both notched and notchless variants.

---

## How to log a bug
Add entries below under the right section. Use this format:

```
### BUG-N: Short title
- **Variant:** Notched | Notchless | Both
- **Reproduce:** Steps to trigger
- **Observed:** What actually happens
- **Expected:** What should happen
- **Frequency:** Always | Sometimes | Rare
- **Notes:** Any extra context, error from console, etc.
```

---

## Open Bugs

<!-- Add new bugs here -->

### single app icon in full width - still random app icon (it should be APUI only) just sits in the center
- **Variant:** Notchless
- **Reproduce:** Random and sometimes from sleep to wake triggers it
- **Observed:** just a single app icon and the pill is at full width
- **Expected:** single app icon needs to wrapped with a responsive pill
- **Frequency:** Sometimes


### Settings and Edit button not working from DD 
- **Variant:** Notchless
- **Reproduce:** Clicking the settings and edit button from dropdown doesnt trigger the settings dialog box
- **Observed:** the dropdown closes
- **Expected:** open settings and letting the app edit the placement
- **Frequency:** Always

### Claude's rate limit tracking is breaking 
- **Variant:** Both
- **Reproduce:** Launch app with no OAuth token in Keychain (current state)
- **Observed:** Rate limit pill stuck at 0%
- **Expected:** Should show weekly token usage vs plan cap, or real rate-limit % if OAuth token present
- **Frequency:** Always
- **Root cause:** No OAuth token (`sk-ant-oat01-…`) in Keychain → falls back to local JSONL path. `stats-cache.json` is stale (last computed 2026-03-08), has no recent daily token entries → `weeklyTokens` = only today's live JSONL count, which starts at 0 until an active session fires. Math is correct; data source is stale/empty. Fix: either prompt user to run `claude setup-token` and save the OAuth token, OR make the fallback path pull token totals from the live JSONL scan directly (not stats-cache) so percentage reflects actual recent usage without needing the API key.

### On hover the pill doesnt wrap around the app icons
- **Variant:** Notchless
- **Reproduce:** Random hover
- **Observed:** On hover the pill doesnt wrap around the app icons
- **Expected:** the pill and the app icons are a component so on hover both should show up
- **Frequency:** Sometimes

### Dropdown not closing on click - it is now closing but the settings and edit button are not workingß
- **Variant:** =Notchles
- **Reproduce:** Once the dropdown is triggered it just minimizes itself in a set period and not on click
- **Observed:** Once the dropdown is triggered it just minimizes itself in a set period and not on click
- **Expected:** It should close when the click is on center of the notch or outside of the dropdown and also close on clicking the settings button and the settings dialog box should open and this should automatically close down on minimize itsel
- **Frequency:** Always

### On hover out sometimes the pill gets stuck in full width with APUI which works but the pill is stuck and then it closes to the APUI based proper pill
- **Variant:** =Notchless
- **Reproduce:** On hover out sometimes the pill gets stuck in full width with APUI which works but the pill is stuck and then it closes to the APUI based proper pill
- **Observed:** On hover out sometimes the pill gets stuck in full width with APUI which works but the pill is stuck and then it closes to the APUI based proper pill
- **Expected:** on hover out it should be APUI or if no APUI then just default idle
- **Frequency:** Sometimes

### When the app open the notch shows just antigravity instead of all the app providers that are connected which is hover state
- **Variant:** Notchless
- **Reproduce:** when the app runs for the first time
- **Observed:** When the app open the notch shows just antigravity instead of all the app providers that are connected which is hover state
- **Expected:** Hover state
- **Frequency:** Always

### On hover the notch gets stuck on hover state
- **Variant:** Notched
- **Reproduce:** Hover and stay for sometime
- **Observed:** on hover for sometime the notch gets stuck even after triggering the dropdown and closing it defaults to hover mode 
- **Expected:** On hover out it should go on the default state
- **Frequency:** Always

---

## Fixed (tracked here after Claude fixes them)

### Settings and Edit button not working from DD -
- **Variant:** Notchless (same fix applied to hardware notch variant)
- **Root cause:** Calling `ConnectionWindowController.shared.open()` directly from the button fired `NSApp.activate(ignoringOtherApps: true)` while the dropdown was still open. This caused the panel to lose focus, triggering `hoverState` → `notchCollapseDropdown` which raced against the settings window opening — the dropdown closed mid-transition and the window never appeared.
- **Fix:** Settings button now posts `notchCollapseDropdown` first, waits 350ms for the collapse animation to finish, then opens the settings window. Applied to both `ExternalMonitorView.swift` and `NotchRootView.swift`.

### Single app icon in full width (sleep/wake)
- **Variant:** Notchless
- **Root cause:** `refreshAfterWake()` in `NotchWindowBase` reinstalled the hover monitor and updated the strip frame, but never reset the SwiftUI pill state (`pillW`, `pillPhase`, `iconsSpread`). After wake, the view's state was stale — `pillPhase=2` with `pillW` set to the pre-sleep full width — so the pill rendered at that stale width with no matching icons visible.
- **Fix:** Added `notchRefreshAfterWake` notification posted from `refreshAfterWake()`. `ExternalMonitorView` listens and resets all pill state to zero, then re-runs `showWithActivity()` after 100ms if icons are present.

### Claude's rate limit tracking at 0% (how can we not make this occur every again in the future?)
- **Variant:** Both
- **Root cause:** `stats-cache.json` was stale (last computed 2026-03-08). `weeklyTokens` pulled from `dailyModelTokens` which had no entries for dates in the past 7 days → `pastTokens = 0`. No OAuth token in Keychain so the rate-limit API fetcher was skipped entirely.
- **Fix:** Extended `scanAllJSONL` to count tokens across the full past 7 days from JSONL files (not just today). Added `liveTokensWeekly` published var. `weeklyTokens` now prefers `liveTokensWeekly` when it has data, falling back to stats-cache only when the live scan hasn't run yet.
