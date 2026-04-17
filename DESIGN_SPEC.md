# TrackNotch Design Spec
> Source of truth: Figma screenshots in `/Users/manojachari/trackllmall/Figma reference/`

---

## Pill / Wing Layout

```
[LEFT WING] [----NOTCH (hardware cutout)----] [RIGHT WING]
```

- **Pill background**: pure black (`#000000`) — blends seamlessly with hardware notch
- Notch block: hardware-measured, typically ~208pt wide, ~37–39pt tall
- Left wing: mixed providers (Cursor, OpenAI API, Codex in Figma samples)
- Right wing: mixed providers (Claude Code, Anthropic API, Antigravity, Google)
- Wing width: dynamic — sized to fit the number of active icons (no fixed width)

### Spacing
| Property | Value |
|---|---|
| Outer horizontal padding (pill edge → first icon) | `14pt` |
| Inner horizontal padding (notch edge → last icon) | `10pt` |
| Gap between icons | `10pt` |
| Icon container size | `22 × 22pt` |
| Icon image size (left wing, with arc) | `14 × 14pt` inside 22pt container |
| Icon image size (right wing, API) | `14 × 14pt` |

---

## Icon Types

### Subscription / Local Monitor Icons (on either wing)
- **No circle background** — icon sits bare directly on black pill
- **Arc**: thick partial ring wrapped AROUND icon; gap at top (~12 o'clock)
- Arc start angle: top-right (~1 o'clock), sweeps clockwise, gap centered at top
- Arc stroke width: `3.5pt`, lineCap `.round`
- Arc frame: outer diameter ~`22pt` (roughly 1.5× icon image)
- Arc length mapping (from Figma variants):
  - <20% → ~90° (upper-right quadrant only)
  - 50% → ~180°
  - <75% → ~270° (gap at top)
  - >75% → ~320° (small gap at top)
  - 100% → full ring
- Icon image: `14×14pt`, full-color SVG (not template), centered inside arc
- Providers: Claude Code, Codex, Cursor, Antigravity (any subscription-metered LLM)

### API Token Icons (on either wing)
- **No circle background** — bare icon
- Icon image: `14×14pt`, full-color SVG, bottom-left anchored in 22pt container
- White "burst/asterisk" marker beside icon (see Figma API token screenshots)
- Orange upward arrow (`ArrowTickerView`) in top-right of container, animates when consuming
- Arrow size: ~`8pt`, color `#ff9b2f`
- Providers: OpenAI API, Anthropic API, Google (Gemini), any API-metered provider

---

## Arc / Ring Colors (usage thresholds)
| Usage | Color | Hex |
|---|---|---|
| 0–19% | Lime green | `#b4e50d` |
| 20–74% | Orange | `#ff9b2f` |
| 75–100% | Red | `#fb4141` |

---

## Concurrent App States (from Figma)

Confirmed from `1-6 concurrent apps.png` screenshots. Wing assignment is fixed per provider and growth is outward from the notch.

| # Active | Left wing (reading L→R) | Right wing (reading L→R) |
|---|---|---|
| 0 | — (pulsing `+` in single wing) | — |
| 1 | — | Claude Code (arc) |
| 2 | Codex (arc) | Claude Code (arc) |
| 3 | Codex (arc) | Claude Code (arc) + Anthropic API (arrow) |
| 4 | Antigravity + Codex | Claude Code + Anthropic API (arrow) |
| 5 | Antigravity + Codex | Claude Code + Anthropic API (arrow) + Google (arrow) |
| 6 | OpenAI (arrow) + Codex | Claude Code + Anthropic API (arrow) + Antigravity + Google (arrow) |
| 6b | Cursor + Codex + Antigravity (no arrow apps) | Claude Code + Anthropic API (arrow) + Antigravity + Google (arrow) |

---

## Dropdown Panel (`clicked.png`)

### Container
- Width: `~180pt` (compact)
- Background: dark rounded pill / panel
- Corner radius: ~`12pt`
- Shadow: black, radius 12

### Provider Rows
- Each row: icon + cost/usage label + colored progress bar + small arc/arrow indicator
- Cost display: `$2.7`, `$12`, `$16` (dollar amounts for API)
- Subscription: percentage `%`
- Bar colors: green (low) → orange (mid) → red (high) matching usage thresholds
- Small icon on right side of bar

### Header
- `edit` button top-left, `settings` button top-right

---

## Glow Border
- Orange animated rotating gradient when providers active
- glowColor: `Color(red: 0.9, green: 0.4, blue: 0.1)` (`#e6651a`)
- brightColor: `Color(red: 1.0, green: 0.55, blue: 0.2)` (`#ff8c33`)
- On startup: 3s glow then fades out
- On activity change: fades in/out with `.easeIn 0.2s`

---

## No LLM Active State
- Pill shows just the black notch shape, no icons
- Pulsing `+` add button in left wing

---

## Colors Reference
| Name | Hex | Usage |
|---|---|---|
| Pill background | `#000000` | Pure black — merges with hardware notch |
| Lime green | `#b4e50d` | Low usage arc (0–19%), connected state |
| Orange | `#ff9b2f` | Mid usage arc (20–74%), API arrow, Claude accent |
| Red | `#fb4141` | High usage arc (75–100%), errors |
| Teal | `#74aa9c` | OpenAI / Codex / ChatGPT accent |

---

## Animation Specs
| Element | Animation |
|---|---|
| Icon appear/disappear | `.scale + .opacity` transition |
| Arc fill | `.easeOut` 0.8s on appear, 0.5s on change |
| Glow border | Rotating `AngularGradient` at 25 FPS |
| Provider list spring | `.spring(response: 0.3, dampingFraction: 0.7)` |
| Arrow ticker | `.linear 1s` repeat when consuming |
