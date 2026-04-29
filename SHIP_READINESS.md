# TrackNotch — Ship Readiness Checklist

Status: **6.8 / 10 — beta-ready, not 1.0-ready.** Target: ship a signed, notarized public 1.0 build.

Each item has: priority (P0 blocker → P3 nice-to-have), rough effort, and acceptance criteria. Work top-to-bottom inside each priority band.

---

## P0 — Release blockers

### 1. Commit the working tree
- **Effort:** 15 min
- **Why:** 20 modified files + 2 deletions are uncommitted. Today's hover-bug regression would have been bisectable if these were small commits.
- **Done when:**
  - `git status` is clean except for ignored files.
  - Deletions of `ProviderManaging.swift` and `EditModeRow.swift` are committed with a message explaining why.
  - `animation.md` is either committed or moved out of the repo.

### 2. Add `.gitignore`
- **Effort:** 5 min
- **Done when:** `.DS_Store`, `xcuserdata/`, `UserInterfaceState.xcuserstate`, `DerivedData/`, `.build/` are all ignored, and the existing tracked `xcuserdata` files are removed via `git rm --cached`.

### 3. Replace unguarded `print()` with a gated logger
- **Effort:** 1–2 hr
- **Why:** 48 `print()` calls in Core spam Console.app in release builds and leak data (API responses, costs, paths).
- **Done when:**
  - New file `Core/Logging/TNLog.swift` exposes `TNLog.debug/info/warn/error(_:category:)` backed by `os.Logger` with subsystem `com.tracknotch.app`.
  - All non-`#if DEBUG` `print(` calls in `TrackNotch/` replaced. (`grep -rn 'print(' TrackNotch/TrackNotch --include='*.swift' | grep -v '#if DEBUG'` returns 0.)
  - Categories used: `auth`, `display`, `monitor.<name>`, `provider.<name>`, `ui`.

### 4. Set up Developer ID signing + notarization
- **Effort:** half a day (first time), 10 min thereafter
- **Done when:**
  - Build target's signing identity is "Developer ID Application: …".
  - `make release` (or equivalent script) produces a signed `.app`, zips it, submits to `notarytool`, staples the ticket, packages a `.dmg`.
  - First-launch on a clean Mac shows no Gatekeeper warning.

### 5. Sandbox / distribution decision
- **Effort:** 1 hr decision + write-up; multi-day if MAS
- **Why:** Current `app-sandbox = false` is required for `~/.claude` etc. but blocks Mac App Store.
- **Done when:** A 1-page `DISTRIBUTION.md` records the decision (direct distribution via website vs MAS via XPC helper) and links to the entitlements rationale.

### 6. App icon + asset audit
- **Effort:** 1 hr
- **Done when:**
  - `Assets.xcassets/AppIcon.appiconset` has all required sizes (16–1024).
  - All provider icons (`claude-color`, `codex`, `cursor`, `antigravity`, `openai`) exist and render at 1x/2x/3x.
  - No "missing image" warnings in build log.

---

## P1 — Required for a credible 1.0

### 7. Unit-test target + first tests
- **Effort:** 2–3 hr to set up + per-test time
- **Done when:**
  - `TrackNotchTests` target exists in the Xcode project, hooked to ⌘U.
  - Tests in `TESTING_PLAN.md` (below) all pass.
  - CI runs `xcodebuild test` on every PR.

### 8. Bundle version automation
- **Effort:** 30 min
- **Done when:**
  - `CFBundleVersion` is auto-incremented from git commit count (`Run Script` build phase).
  - `CFBundleShortVersionString` is set from a `VERSION` file.

### 9. Crash + error reporting (offline-friendly)
- **Effort:** 2 hr
- **Why:** Today there is no way to know if a user's Keychain failed or a fetcher hit a 4xx loop.
- **Done when:**
  - Failures land in `~/Library/Logs/TrackNotch/`.
  - A "Reveal logs in Finder" menu item exists in Settings.
  - No third-party telemetry (privacy posture preserved).

### 10. README + screenshots
- **Effort:** 1 hr
- **Done when:** `README.md` covers: what it is, supported providers, install (.dmg), first-run setup, FAQ on permissions, link to PRD.

### 11. Privacy policy / data handling note
- **Effort:** 30 min
- **Done when:** `PRIVACY.md` documents: keys live in Keychain, file reads are local-only, no network egress except the listed provider APIs, no analytics.

### 12. First-launch onboarding
- **Effort:** 3–4 hr
- **Done when:** First launch shows a one-screen explainer (notch UI, where to add API keys, "open at login" prompt). Subsequent launches skip it.

---

## P2 — Quality and polish

### 13. Replace the manual hit-rect math with a single source of truth
- **Effort:** 2 hr
- **Why:** Today's bug was `hoverRect` and the SwiftUI pill drifting apart. They should derive from one constant.
- **Done when:** Pill geometry (height, top padding, side padding) lives in a `PillGeometry` struct used by both `ExternalMonitorView` and `NotchWindow.hoverRect`.

### 14. Reduce Combine fanout in `ProviderRegistry`
- **Effort:** 2 hr
- **Done when:** Each monitor publishes a single `ProviderUsage` via `@Published`, registry uses a single merged stream rather than per-monitor `objectWillChange.sink`.

### 15. Fix silent error sinks
- **Effort:** 1 hr
- **Done when:** `requestNotificationPermission { _, _ in }` and similar log on failure; no closure body is `{ _ in }`.

### 16. Add accessibility labels
- **Effort:** 2 hr
- **Done when:** Every `Button` and tappable area in `ExternalMonitorView`, `DropdownPanelView`, `SettingsView` has `.accessibilityLabel(_:)`. VoiceOver can navigate the dropdown.

### 17. Light-mode support OR explicit dark-only declaration
- **Effort:** 30 min (declaration) / 1 day (full support)
- **Done when:** Either `NSRequiresAquaSystemAppearance` set in Info.plist with rationale, or all hard-coded colors respect `Color(.windowBackgroundColor)` etc.

### 18. Sleep/wake + display-change soak test
- **Effort:** 1 hr manual
- **Done when:** A documented checklist (`TESTING_PLAN.md` § Manual) is run before each release: lid close/open, plug/unplug external, change resolution, log out/in.

---

## P3 — Nice to have

### 19. Sparkle (or similar) auto-update
### 20. Localized strings extraction (English-only is fine for 1.0; just stop hard-coding).
### 21. Per-provider "Last fetched at" surfacing in the dropdown.
### 22. Telemetry-free anonymous crash reports via local log bundle the user can attach to a GitHub issue.

---

## Definition of Ship-Ready (1.0)

All P0 + P1 items checked, P2 items 13–16 checked, manual soak test (#18) passed twice on different hardware (notched MacBook + non-notched + external).
