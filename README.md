# TrackNotch

A native macOS menu-bar app that tracks your LLM usage in real time — across Claude, OpenAI, Cursor, Google, Codex, and Antigravity — and surfaces it in the notch (or top of the menu bar on non-notched Macs).

No proxies. No cookies. No telemetry. Usage data is read locally from the providers' own files and APIs, and your API keys live in the macOS Keychain.

## Supported providers

| Provider | What it tracks |
|---|---|
| Claude (Anthropic) | API spend + Claude Code session usage |
| OpenAI | API spend |
| Cursor | Subscription usage |
| Google (Gemini) | API spend |
| Codex | Session usage |
| Antigravity | Session usage |

## Install

1. Download the latest `TrackNotch-x.y.z.dmg` from [Releases](https://github.com/manojacharix/trackllmall/releases).
2. Open the DMG and drag **TrackNotch.app** into **Applications**.
3. **First launch — important:** because this build is unsigned (no Apple Developer ID yet), macOS Gatekeeper will refuse to open it normally. Instead:
   - In Finder, open `Applications`.
   - **Right-click** `TrackNotch.app` → **Open** → **Open** in the dialog.
   - This only needs to be done once. After that, launch it normally.
   - If macOS still blocks it, run `xattr -cr /Applications/TrackNotch.app` in Terminal and retry.

A signed and notarized build is on the roadmap (see [Roadmap](#roadmap)).

## First-run setup

1. After launch, the pill appears at the top of the screen (overlapping the notch on notched Macs, or the menu bar otherwise).
2. Click the pill → dropdown opens → **Settings**.
3. Add API keys for the providers you want to track. Keys are stored in the macOS Keychain — never written to disk in plaintext, never sent anywhere except the corresponding provider's API.
4. Usage refreshes automatically and the pill updates live.

## Requirements

- macOS 13 (Ventura) or later
- Apple Silicon or Intel Mac
- An API key for each provider you want to track (Claude Code and Cursor also work via local file monitoring without keys for some metrics)

## Privacy

See [PRIVACY.md](PRIVACY.md). The short version:

- API keys are stored in the macOS Keychain.
- Local file reads are scoped to the providers' own data directories (e.g. `~/.claude`).
- Network requests only go to the official provider APIs you've configured.
- Zero analytics, zero telemetry, zero third-party services.

## Why is the app not sandboxed?

TrackNotch reads provider data from locations like `~/.claude` that lie outside the App Sandbox. To support those flows without prompting for user-selected folder access on every launch, the app ships unsandboxed and is distributed directly (not via the Mac App Store). The trade-off is documented and intentional.

## Roadmap

- [ ] Apple Developer ID signing + notarization (no more right-click-Open)
- [ ] First-launch onboarding
- [ ] Auto-update via Sparkle
- [ ] Crash/error logs in `~/Library/Logs/TrackNotch/`
- [ ] Light-mode support

## Building from source

```bash
git clone https://github.com/manojacharix/trackllmall.git
cd trackllmall
open TrackNotch/TrackNotch.xcodeproj
```

Xcode 15+, macOS 13 SDK or later. Press ⌘R to run, ⌘U to run the test suite (34 unit tests).

To build a DMG locally:

```bash
./scripts/build-release.sh
```

Output: `build/TrackNotch-<version>.dmg`.

## Contributing

Bug reports and PRs welcome. Please open an issue first for anything bigger than a small fix so we can discuss approach.

## License

[MIT](LICENSE) © 2026 Manoj Achari
