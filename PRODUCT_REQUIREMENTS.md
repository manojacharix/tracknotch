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
- **Graceful degradation** — works on non-notch Macs as a menu bar item

---

## 4. Window Behavior

### 4.1 Wing Display (notch Macs)

The app occupies the **right wing** of the notch — the black area to the right of the physical notch cutout. Content is permanently visible without obscuring the notch itself.

```
┌──────────────────────────────────────────────────────────┐
│  [menu bar items...]   ███ NOTCH ███   $1.24 ▌cl gpt ▌  │
│                                         RIGHT WING       │
└──────────────────────────────────────────────────────────┘
```

### 4.2 Auto-Collapse (Idle Behavior)

When there is no active LLM token usage, the wing widget **folds into the notch** (collapses to invisible / minimal state).

**Default behavior:** Collapse after **30 minutes** of inactivity.

**User-configurable options:**
| Option | Description |
|---|---|
| Never collapse | Always show wing widget |
| 5 minutes | Collapse after 5 min of inactivity |
| 15 minutes | Collapse after 15 min of inactivity |
| **30 minutes** (default) | Collapse after 30 min of inactivity |
| 1 hour | Collapse after 1 hour of inactivity |
| When screen locks | Collapse when Mac locks/sleeps |

"Inactivity" = no new tokens tracked across any connected provider.

**Re-expand trigger:** Any new token usage from any provider automatically re-expands the wing.

### 4.3 Expanded Panel (on click)

Clicking the wing widget expands a panel downward showing full usage details per provider.

### 4.4 Fallback (non-notch Macs)

On Macs without a notch, the app falls back to a standard **menu bar item** with the same expanded panel on click.

---

## 5. Providers

### 5.1 V1 Priority Providers

These are the core 5 providers targeting power users and general users who use LLMs to get work done.

| Priority | Provider | Auth Method | What is tracked | User type |
|---|---|---|---|---|
| 1 | **Claude / Claude Code** | Session cookie → claude.ai API + `~/.claude/` JSONL | 5-hour %, 7-day %, plan tier, reset time, active session tokens | All users |
| 2 | **ChatGPT** (OpenAI) | Session cookie (web) + API key (API users) | Plus/Pro quota %, API monthly spend, per-model breakdown | All users |
| 3 | **Cursor** | Local file read (`~/.cursor/`) | Session token usage, monthly spend vs plan | Developers |
| 4 | **Codex** (OpenAI) | Local JSONL (`~/.codex/`) | Token usage per session, cost estimate | Developers |
| 5 | **Antigravity** | Google session cookie → Gemini quota API | Usage vs Gemini quota (shared) | Developers |

### 5.2 Tier 1 — Full Support (reliable)

| Provider | Auth Method | What is tracked |
|---|---|---|
| **Claude** (Anthropic) | Session cookie → claude.ai internal API | 5-hour rolling limit %, 7-day limit %, plan tier (Free/Pro/Max/Team), reset time |
| **ChatGPT / OpenAI API** | Session cookie (web) + API key | Plus/Pro quota, monthly API spend, per-model breakdown |
| **Cursor** | Local file read (`~/.cursor/`) | Session usage, plan limits |
| **Codex CLI** | Local JSONL (`~/.codex/sessions/`) | Token counts, cost estimate |

### 5.3 Tier 2 — Best Effort (may break on provider changes)

| Provider | Auth Method | What is tracked | Notes |
|---|---|---|---|
| **Antigravity** | Google session cookie → Gemini quota API | Usage vs Gemini quota | Antigravity is Google's Gemini-powered IDE (VS Code-based). Stores conversations as binary protobuf (`.pb`) — not parseable like JSONL. Shares Gemini model quota with Google account. Tracked same way as Gemini web. |
| **Gemini / Gemini CLI** | Local file read (`~/.gemini/`) + Google session cookie | Monthly token count, approx cost | CLI logs at `~/.gemini/`; Antigravity sessions at `~/.gemini/antigravity/` |
| **ChatGPT web** | Session cookie scraping | Best-effort quota display | No official consumer quota API |

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
● Claude     ████████░░  82%    resets in 1h 20m
● OpenAI     ████░░░░░░  38%    $7.60 / $20.00
● DeepSeek   ██░░░░░░░░  19%    resets in 12d
● Gemini     █░░░░░░░░░   9%    ~est.
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
