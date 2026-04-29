# TrackNotch Animation Reference

## Overview

All animations follow a **dissolve-then-move** principle: content fades out in place first, then the container shape changes independently. This prevents elements from visually escaping their bounds during transitions.

---

## Notch Pill (Built-in Display)

**File:** `Views/Notch/NotchRootView.swift`

### Expand (idle → active icons appear)
| Phase | What happens | Animation | Duration | Delay |
|-------|-------------|-----------|----------|-------|
| 1 | Pill wings expand outward from notch | `interactiveSpring(response: 0.38, damping: 0.82)` | ~380ms | 16ms (1 frame) |
| 2 | Icons slide in from notch center + fade in | `interactiveSpring(response: 0.34, damping: 0.78)` | ~340ms | 120ms after pill starts |
| — | Per-icon stagger (outer → inner) | — | — | 50ms per icon |

### Collapse (active → idle, icons leave)
| Phase | What happens | Animation | Duration | Delay |
|-------|-------------|-----------|----------|-------|
| 1 | Icons dissolve in place (opacity only, no movement) | `easeOut` | 250ms | 0ms |
| 2 | Pill wings shrink back into notch | `easeInOut` | 300ms | 300ms (after icons gone) |

### Expand Dropdown (pill → card)
| Phase | What happens | Animation | Duration | Delay |
|-------|-------------|-----------|----------|-------|
| 1 | Icons dissolve | `easeOut` | 120ms | 0ms |
| 2 | Shape grows to 380px card | `interactiveSpring(response: 0.5, damping: 0.85)` | ~500ms | 100ms |
| 3 | Dropdown content fades in | `easeOut` | 200ms | 320ms |

### Collapse Dropdown (card → pill)
| Phase | What happens | Animation | Duration | Delay |
|-------|-------------|-----------|----------|-------|
| 1 | Dropdown content fades out | `easeInOut` | 180ms | 0ms |
| 2 | Shape shrinks back to pill | `interactiveSpring(response: 0.48, damping: 0.88)` | ~480ms | 160ms |
| 3 | Wing icons re-expand (if still active) | calls `expand()` | — | 460ms |

---

## External Monitor Pill (Clamshell / External Display)

**File:** `Views/Notch/ExternalMonitorView.swift`

### Show (no activity → icons appear)
| Phase | What happens | Animation | Duration |
|-------|-------------|-----------|----------|
| 1 | Pill scales up (0.6 → 1.0) + fades in | `.smooth` | 300ms |
| 2 | Icons slide in from center + fade in (staggered) | `.smooth` | 300ms + 50ms/icon |

### Collapse (activity stops → pill disappears)
| Phase | What happens | Animation | Duration | Delay |
|-------|-------------|-----------|----------|-------|
| 1 | Icons dissolve in place (opacity to 0) | `easeOut` | 250ms | 0ms |
| 2 | Pill shrinks to dot (8px) | `.smooth` | 350ms | 300ms (after icons gone) |
| 3 | Dot fades out | `.smooth` | 300ms | 650ms |

### Expand Dropdown
| Phase | What happens | Animation | Duration | Delay |
|-------|-------------|-----------|----------|-------|
| 1 | Shape grows to 380px card | `.smooth` | 400ms | 0ms |
| 2 | Dropdown content fades in | `easeOut` | 200ms | 250ms |

### Collapse Dropdown
| Phase | What happens | Animation | Duration | Delay |
|-------|-------------|-----------|----------|-------|
| 1 | Content fades out | `easeOut` | 150ms | 0ms |
| 2 | Shape shrinks back to pill | `.smooth` | 350ms | 120ms |

---

## Icon-Level Animations

### NotchSlideIcon (Notch wings)
**File:** `Views/Notch/NotchRootView.swift`

- **Enter:** Slides in from notch center + fades in. Spring animation, staggered 50ms per icon (outer icons first).
- **Exit:** Dissolves in place (opacity only, no sliding). `easeOut`, 250ms. Position resets silently after dissolve.

### External Monitor Icons
**File:** `Views/Notch/ExternalMonitorView.swift`

- **Enter:** Slides in from center + fades in. `.smooth(0.3)`, staggered 50ms per icon.
- **Exit:** Opacity fade only (no slide). `easeOut(0.20)`, staggered 50ms per icon.

---

## Arrow Ticker (API spend indicator)

**File:** `Views/Wing/ArrowTickerView.swift`

- **Active:** 9pt heavy upward arrow drifts up 9px and fades out over 0.8s, snaps back, repeats. Color: `#ff9b2f`.
- **Idle → Active:** Loop starts immediately.
- **Active → Idle:** Arrow eases back to origin (0.25s), opacity returns to 0.7.

---

## Pill Shape

**File:** `Views/Notch/NotchShape.swift`

All pill width/height changes use `interactiveSpring(response: 0.45, damping: 0.82)` on the notch, `.smooth(0.35)` on external monitor. The shape itself (`NotchShape` / `RoundedRectangle`) is always in the view tree — only its frame animates.

---

## Design Principles

1. **Dissolve before move** — Content fades out in place before containers resize. Prevents content escaping bounds.
2. **Stagger from edges** — Icons closest to the notch/center enter first, outermost last. Reverse for exit.
3. **Springs for expansion, easing for collapse** — Expanding feels energetic (spring overshoot). Collapsing feels calm (smooth ease).
4. **Pill always in tree** — The pill shape is never removed from the SwiftUI view tree. Only its dimensions and opacity change. This avoids jarring insert/remove transitions.
5. **Icons use opacity for exit** — On collapse, icons dissolve with opacity. No sliding out — that caused icons to visually escape the pill bounds.
