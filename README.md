<p align="center">
  <img src="branding/TrackNotch logos/variations/tracknotch_dark_logo.png" alt="TrackNotch" width="120" />
</p>

<h1 align="center">TrackNotch</h1>

<p align="center">
  Real-time LLM usage tracking — right in your Mac's notch.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13%2B-black?style=flat-square&logo=apple" />
  <img src="https://img.shields.io/badge/Swift-5.9-orange?style=flat-square&logo=swift" />
  <img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" />
  <img src="https://img.shields.io/badge/status-beta-yellow?style=flat-square" />
</p>

---

TrackNotch is a native macOS app that monitors your LLM usage across Claude, OpenAI, Cursor, Codex, and more — and surfaces it in the notch (or top of the menu bar on non-notched Macs). No proxies. No cookies. No telemetry.

## Features

| | |
|---|---|
| **Local-first** | Reads usage directly from providers' own files and APIs. Nothing leaves your machine. |
| **Multi-provider** | Claude Code, OpenAI API, Cursor, Codex, Anthropic API, Google Gemini — all in one pill. |
| **Context arc** | Visual arc shows how full your active Claude session's context window is, live. |
| **Budget tracking** | Set monthly budgets for OpenAI (admin key) and Anthropic (org admin key). See spend at a glance. |
| **Rate-limit headers** | OAuth token support for real 5h/7d Claude rate-limit data from Anthropic's headers. |
| **Notch-native** | Slides out of the notch with a springy open animation and clean ease-in close. |
| **Menu bar fallback** | Works on non-notched Macs too — sits cleanly in the menu bar. |
| **Keychain storage** | API keys stored in macOS Keychain. Never written to disk in plaintext. |

## Supported Providers

| Provider | Tracks |
|---|---|
| **Claude Code** | Session context usage, 5h/7d rate limits via OAuth |
| **Anthropic API** | Monthly org-wide spend — requires an Admin key (`sk-ant-admin-…`). Individual API keys not supported. |
| **OpenAI API** | Monthly API spend — requires an Admin key (`sk-admin-…`) |
| **Cursor** | Subscription fast-request usage |
| **Codex** | Session usage |

## Install

1. Download the latest `TrackNotch-x.y.z.dmg` from [Releases](https://github.com/manojacharix/tracknotch/releases).
2. Open the DMG and drag **TrackNotch.app** into **Applications**.
3. **First launch:** Because this build is unsigned, macOS Gatekeeper will block it.
   - In Finder → Applications → **right-click** `TrackNotch.app` → **Open** → **Open**.
   - This one-time step is enough. After that, launch normally.
   - If still blocked: `xattr -cr /Applications/TrackNotch.app` in Terminal, then retry.

> Signed + notarized build is on the roadmap — no more right-click needed.

## Setup

1. Launch TrackNotch — the pill appears at the top of your screen.
2. Click the pill → dropdown opens → **Settings**.
3. Paste API keys for the providers you want to track. For Anthropic and OpenAI cost tracking, admin-level keys are required.
4. For Claude Code rate-limit tracking, add your OAuth token (Settings → Claude Code → Rate-limit tracking).
5. Usage refreshes automatically and the pill updates live.

### Claude Code context arc

TrackNotch reads Claude Code's local JSONL session files to calculate context usage. No token or key needed.

To also get real 5h/7d rate-limit data, add an OAuth token:

```bash
# Install Claude Code if you haven't already
npm install -g @anthropic-ai/claude-code

# Generate an OAuth token
claude setup-token
```

Paste the token (starts with `sk-ant-oat01-…`) into Settings → Claude Code → Rate-limit tracking.

## Requirements

- macOS 13 (Ventura) or later
- Apple Silicon or Intel Mac
- API keys for providers you want to track (Claude Code and Cursor work via local monitoring without keys)

## Privacy

All data stays local. Full details in [PRIVACY.md](PRIVACY.md).

- API keys → macOS Keychain only
- Local reads scoped to provider data dirs (`~/.claude`, etc.)
- Network requests only to provider APIs you configure
- Zero analytics, zero telemetry, zero third-party services

## Why is the app unsandboxed?

TrackNotch reads provider data from locations like `~/.claude` that are outside the App Sandbox. Shipping unsandboxed avoids per-launch folder-access prompts. The tradeoff is documented and intentional — see [PRIVACY.md](PRIVACY.md).

## Building from Source

```bash
git clone https://github.com/manojacharix/tracknotch.git
cd tracknotch/TrackNotch
open TrackNotch.xcodeproj
```

Requires Xcode 15+ and macOS 13 SDK. Press `⌘R` to run, `⌘U` for the test suite.

```bash
# Build a DMG locally
./scripts/build-release.sh
# Output: build/TrackNotch-<version>.dmg
```

## Roadmap

- [ ] Apple Developer ID signing + notarization
- [ ] Auto-update via Sparkle
- [ ] First-launch onboarding flow
- [ ] Light-mode support
- [ ] Crash logs in `~/Library/Logs/TrackNotch/`

## Contributing

Bug reports and PRs welcome. Open an issue first for anything larger than a small fix.

## License

[MIT](LICENSE) © 2026 Manoj Achari
