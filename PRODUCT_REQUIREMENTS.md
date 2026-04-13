# LLM Usage Tracker — Product Requirements Document

> Working title: **NotchLLM** (to be renamed)
> Last updated: 2026-04-08
> Target user updated: Power users + general users who use LLMs to get work done

---

## 1. Overview

A macOS menu bar / notch-wing app that shows real-time LLM usage across multiple AI providers — always visible, always local, zero backend.

**Core insight:** Every other LLM tracker lives in the menu bar (crowded) or overlays the notch (only active during sessions). This app lives in the **notch wings** — the permanently visible dead zones on either side of the physical notch — giving users a glanceable, always-on usage dashboard without cluttering the menu bar.

---

## 2. Target Users

**Primary:** Power users and general users who use LLMs daily to get work done — not just developers, but anyone who relies on AI tools to be productive.

**User profiles:**
- A developer using Claude Code + Cursor + Codex across multiple projects
- A designer/writer using ChatGPT heavily for content and switching to Claude for coding
- A product manager using multiple tools and wanting to know where their money is going
- Anyone on a paid plan who hits limits unexpectedly

**NOT targeting:**
- Pure API builders tracking programmatic usage (they have dashboards already)
- Enterprise teams (v1 is single-user, local Mac only)

---

## 3. Core Design Principles

- **Always local** — all credentials and usage data stay on the user's Mac (Keychain, local files). No backend server, no telemetry sent anywhere.
- **Always visible** — lives in the notch wing, not hidden behind a click
- **Zero config where possible** — auto-detects Claude, Gemini CLI from local files; only API keys needed for API-based providers
- **Consistent experience across displays** — hardware notch uses physical cutout as anchor; all other screens render a software notch identical in shape

---

## 4. Window Behavior

### 4.1 Display Mode Detection

The app detects the display configuration at launch and on screen change, and renders accordingly:

| Scenario | Behavior |
|---|---|
| **MacBook with physical notch** | Wing slides out beside the real hardware notch cutout. App only occupies the wing area — physical notch stays as-is. |
| **MacBook without notch** | App renders a **software notch** — draws the full notch shape (black, same curve as hardware notch) at top center of screen. Wings slide out from either side of this drawn shape. |
| **External display only** (clamshell or standalone) | App renders a software notch on the external display — same as above. |
| **Extended display** (MacBook + external) | App renders on **both screens independently** — hardware notch on MacBook, software notch on external display. Each shows the same usage data. |
| **Mirroring** | Renders on primary screen only. Mirror naturally duplicates it. |

### 4.2 Hardware Notch Mode

The app occupies the **right wing** — the black area to the right of the physical notch cutout. The physical notch center is untouched.

```
┌──────────────────────────────────────────────────────────┐
│  [  menu bar items  ]  ▓▓▓NOTCH▓▓▓  [ claude icon ]     │
│                         (physical)    RIGHT WING         │
└──────────────────────────────────────────────────────────┘
```

### 4.3 Software Notch Mode

The app draws the **entire notch shape** at top center — a black rounded-rectangle cutout identical in appearance to the hardware notch. Wings extend from both sides of this drawn shape. The menu bar on the left of the software notch is empty (app owns that space).

```
┌──────────────────────────────────────────────────────────┐
│               ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  [ claude icon ]     │
│               (app-drawn notch shape)  RIGHT WING        │
└──────────────────────────────────────────────────────────┘
```

The software notch shape matches the hardware notch dimensions (approx 126×37pt) so the experience is visually identical across all display types.

### 4.4 Wing Appearance (both modes)

- App icons appear in the **right wing** beside the notch
- Each active provider shows as a **circular icon** with a color ring indicating usage level
- Wings are only visible when at least one provider is active (see §4.5)

### 4.5 Auto-Collapse (Idle Behavior)

The notch **only appears when an LLM app is actively being used**. When no usage is detected:
- Wing shrinks → scales down to a circle → shrinks to a dot → disappears (2 second animation)
- After the configured idle timeout, the entire notch hides

**Default behavior:** Collapse after **30 minutes** of inactivity.

**User-configurable options:**
| Option | Description |
|---|---|
| Never collapse | Always show when any provider is connected |
| 5 minutes | Collapse after 5 min of inactivity |
| 15 minutes | Collapse after 15 min of inactivity |
| **30 minutes** (default) | Collapse after 30 min of inactivity |
| 1 hour | Collapse after 1 hour of inactivity |
| When screen locks | Collapse when Mac locks/sleeps |

"Inactivity" = no new tokens tracked across any connected provider for the duration.

**Re-expand trigger:** Any new token usage from any provider re-expands the wing with the slide-out animation.

### 4.6 Expanded Panel (on click)

Clicking the wing expands a dropdown panel showing per-provider usage bars + cost. Gradients used in dropdown view only; solid colors in wing icons.

---

## 5. Providers

### 5.1 V1 Priority Providers

These are the core 5 providers targeting power users and general users who use LLMs to get work done.

| Priority | Provider | Auth Method | What is tracked | User type |
|---|---|---|---|---|
| 1 | **Claude / Claude Code** | Session cookie → claude.ai API + `~/.claude/` JSONL | 5-hour %, 7-day %, plan tier, reset time, active session tokens | All users |
| 2 | **ChatGPT + Codex** (OpenAI) | ChatGPT session cookie / account | Plan quota %, Codex request usage — single unified account | All users |
| 3 | **Cursor** | Local file read (`~/.cursor/`) | Fast request quota used vs plan limit (500/mo on Pro) | Developers |
| 4 | **Antigravity** | Google session cookie → Google AI plan API | Agent request quota by plan tier (Plus/Pro/Ultra) | Developers |

### 5.2 Tier 1 — Full Support (reliable)

| Provider | Auth Method | What is tracked |
|---|---|---|
| **Claude** (Anthropic) | Session cookie → claude.ai internal API | 5-hour rolling limit %, 7-day limit %, plan tier (Free/Pro/Max/Team), reset time |
| **ChatGPT + Codex** (OpenAI) | ChatGPT session cookie | Plan quota %, Codex usage — both tied to same ChatGPT subscription (Plus/Pro/Business/Edu/Enterprise). Free and Go plans get limited Codex access. No separate Codex subscription. |
| **Cursor** | Local file read (`~/.cursor/`) | Fast request quota (e.g. 500/mo on Pro), fallback to slow requests when exceeded |

### 5.3 Tier 2 — Best Effort (may break on provider changes)

| Provider | Auth Method | What is tracked | Notes |
|---|---|---|---|
| **Antigravity** | Google session cookie → Google AI plan API | Agent request quota (Limited/Higher/Highest by plan) | Tied to Google AI Plus/Pro/Ultra subscription — NOT raw Gemini API tokens. Plan tier controls how many Antigravity agent requests you can run. Stored locally as `.pb` protobuf files — not directly parseable. |
| **Gemini CLI** | Local file read (`~/.gemini/`) + Google session cookie | Daily request limits per Google AI plan tier | Also governed by Google AI Plus/Pro/Ultra plan. CLI logs at `~/.gemini/`. Separate from Gemini API (pay-as-you-go). |
| **ChatGPT web** | Session cookie scraping | Best-effort quota display | No official consumer quota API |

#### Google AI Plans — How They Affect Antigravity + Gemini CLI

These two products are governed by the same Google AI subscription tier (one.google.com/about/google-ai-plans):

| Google AI Plan | Antigravity Limits | Gemini CLI Limits |
|---|---|---|
| **Plus** | Limited | Limited |
| **Pro** | Higher | Higher |
| **Ultra** | Highest | Highest |

This is separate from the **Gemini API** (pay-per-token, API key based, used by developers building apps). Both can exist in parallel:
- **Gemini API** → tracked via API key + token spend (v2)
- **Antigravity + Gemini CLI** → tracked via Google AI plan quota (v1, best-effort)

### 5.4 Future Providers (v2)

- GitHub Copilot
- Windsurf
- Qwen (Alibaba DashScope)
- DeepSeek
- Kimi (Moonshot)
- Ollama (local models)

---

## 6. Wing Widget — Collapsed State

Always-visible compact display in the right notch wing.

**Shows:**
- Total spend today across all providers (e.g. `$1.24`)
- Provider color dots indicating active/warning/critical status
- Subtle animation when tokens are actively being consumed

**Example:**
```
$1.24  ● ● ●
        cl gpt ds
```

Colors:
- Green dot = <50% of limit used
- Orange dot = 50–80% used
- Red dot = 80–100% used
- Grey dot = not configured / no data

---

## 7. Expanded Panel

Drops down on click from the wing widget.

**Header:**
- Today's total spend
- Monthly total spend

**Per-provider rows:**
```
● Claude       ████████░░  82%    resets in 1h 20m  (Pro plan)
● ChatGPT      ████░░░░░░  38%    resets in 3d      (Plus plan)
  └ Codex      ██░░░░░░░░  19%    bundled with ChatGPT
● Cursor       ██████░░░░  61%    310/500 fast reqs
● Antigravity  ███░░░░░░░  30%    Google AI Pro
```

Each row shows:
- Provider color dot
- Provider name
- Usage progress bar (color-coded: green/orange/red)
- Percentage or cost used
- Reset timer or billing cycle info

**Footer:**
- Settings shortcut
- Last refreshed timestamp
- "All data stored locally" privacy badge

---

## 8. Budget & Alerts

### 8.1 Per-Provider Monthly Budget
- User sets a monthly USD budget per provider
- Default: $20/month per provider
- Progress bar fills relative to budget (for API-key providers)

### 8.2 Alert Thresholds
- Configurable alert at X% of budget (default: 80%)
- macOS notification fires when threshold crossed
- Notch wing color shifts to match severity

### 8.3 Alert Severities
| Level | Trigger | Wing color |
|---|---|---|
| Normal | 0–50% | Green |
| Warning | 50–80% | Orange |
| Critical | 80–95% | Red |
| Exceeded | 95–100% | Pulsing red |

---

## 9. Settings

### Providers Tab
- Connect / disconnect each provider
- API key entry (stored in macOS Keychain, never transmitted)
- Connection status badge per provider
- Support tier indicator (Full / Best-effort)

### Display Tab
- Auto-collapse idle timeout (see §4.2 options)
- Wing position: left or right of notch
- Show/hide individual providers in wing
- Compact vs detailed wing display

### Budget Tab
- Monthly budget per provider
- Alert threshold (% of budget)
- Enable/disable notifications

### General Tab
- Launch at login
- Force notch mode (for testing on non-notch Macs)
- Refresh interval override

---

## 10. Privacy & Security

- All API keys stored in **macOS Keychain** with hardware encryption
- No data ever leaves the Mac (all API calls go directly to provider endpoints)
- No analytics, no crash reporting, no telemetry
- App has no outbound connections except to configured provider APIs
- "Privacy first" badge shown in expanded panel

---

## 11. Technical Architecture

### Window System
- `WingPanel` — `NSPanel` subclass, borderless, positioned in `auxiliaryTopRightArea`
- `CGSSpace` at max level — appears above all other windows including full-screen apps
- Collapse animation: width transition into notch over 300ms
- Re-expand animation: width transition out of notch on token activity

### Provider Managers
- Each provider has its own `*UsageManager` conforming to `ProviderManaging` protocol
- `ProviderRegistry` aggregates all providers, drives UI updates
- Adaptive polling: 1 min (active) → 5 min (idle) → stops after collapse timeout

### Data Flow
```
Provider API / Local files
        ↓
*UsageManager (per provider)
        ↓
ProviderRegistry (aggregates)
        ↓
WingPanel UI (SwiftUI)
        ↓
BudgetManager (alerts)
        ↓
macOS UNNotification
```

### Persistence
- API keys: macOS Keychain
- Budget configs: UserDefaults
- Usage history (optional): local JSON in app container

---

## 12. Platform Requirements

- macOS 13.0+ (Ventura)
- MacBook Pro 14" / 16" (2021+) for notch wing mode
- All Macs with macOS 13+ get menu bar fallback
- No iOS / iPadOS version planned

---

## 13. Open Questions / To Decide

- [ ] App name (working title: NotchLLM)
- [ ] Pricing model (free / one-time / subscription)
- [ ] Distribution: App Store vs direct download vs Homebrew
- [ ] Should Claude usage use the existing AgentNotch session-tracking (JSONL) in addition to quota API?
- [ ] Left wing vs right wing as default position
- [ ] Whether to show active token streaming animation in wing during live usage

---

## 14. Out of Scope (v1)

- Windows / Linux support
- Mobile companion app
- Multi-Mac sync
- Team/shared usage dashboards
- Web dashboard
