# Privacy

TrackNotch is designed to be privacy-respecting by default. This document is the source of truth for what data the app handles, where it lives, and where it goes.

## API keys

- Stored exclusively in the **macOS Keychain** (the standard system keystore).
- Never written to disk in plaintext, never logged, never copied to any TrackNotch-controlled location.
- Only used to authenticate requests to the corresponding provider's official API.

## Local file reads

To track session-based usage (e.g. Claude Code, Codex), TrackNotch reads files in the providers' own local data directories — for example `~/.claude/`. These reads are:

- **Local-only.** Nothing read from these files is uploaded anywhere.
- **Scoped.** TrackNotch only reads the specific files needed for usage accounting.
- **Read-only.** The app does not modify provider data files.

## Network egress

The app makes outbound HTTPS requests **only** to the official provider endpoints needed for the providers you've configured:

- `api.anthropic.com` (Claude)
- `api.openai.com` (OpenAI / Codex)
- `api2.cursor.sh` (Cursor)
- `generativelanguage.googleapis.com` (Google / Gemini)

If a provider is not configured (no API key entered), no requests are sent on its behalf.

## What TrackNotch does NOT do

- ❌ No analytics SDKs.
- ❌ No telemetry, crash reporting to third parties, or "phone home" pings.
- ❌ No advertising identifiers.
- ❌ No background uploads of any kind.
- ❌ No proxying of provider traffic — the app is not a man-in-the-middle.

## Verifying the claims

The source code is public ([github.com/manojacharix/trackllmall](https://github.com/manojacharix/trackllmall)). Network egress can be verified with Little Snitch, LuLu, or `nettop`. Keychain storage is observable via Keychain Access.app (search "TrackNotch").

## Contact

Questions or concerns: open an issue at [github.com/manojacharix/trackllmall/issues](https://github.com/manojacharix/trackllmall/issues).
