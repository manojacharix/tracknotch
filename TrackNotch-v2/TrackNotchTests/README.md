# TrackNotchTests

Seed XCTest target. Sonnet (or any agent) should:

1. **Wire up the target in Xcode** (one-time, ~5 min):
   - File → New → Target → macOS → Unit Testing Bundle
   - Product Name: `TrackNotchTests`
   - Target to be Tested: `TrackNotch`
   - Replace the auto-generated `TrackNotchTests.swift` with the files in this folder.
   - Make sure all `*Tests.swift` files here are members of the `TrackNotchTests` target only.
   - For files testing internal types (most of them), the `TrackNotch` target needs `@testable import TrackNotch` to work — verify the test target has `TrackNotch` listed under "Target Dependencies".

2. **Run** with `⌘U` or:
   ```
   cd TrackNotch && xcodebuild -project TrackNotch.xcodeproj -scheme TrackNotch test
   ```

3. **Extend.** Each file ends with a `// TODO(sonnet): …` block listing the next tests to add.

## What's covered today

| File | What it pins down |
|---|---|
| `ProviderModelsTests.swift` | `ProviderUsage` formatters, `usageLevel` thresholds, `ProviderConnectionState.isConnected` |
| `BudgetManagerTests.swift` | Threshold firing once, reset-on-drop, persistence round-trip |
| `ProviderRegistryLingerTests.swift` | The 4-second linger window — the bit that keeps the pill from flickering |
| `NotchWindowGeometryTests.swift` | The `hoverRect` math that broke today — locked-in via a pure helper |
| `NotchModeDetectionTests.swift` | Mode selection rules (documentation-as-test; no NSScreen needed) |

## What is NOT covered (and why)

- **Live network fetchers** (`OpenAIUsageFetcher`, `AnthropicUsageFetcher`) — would need a `URLProtocol` mock. Listed as a TODO inside `ProviderRegistryLingerTests.swift`.
- **AppKit window placement** — needs a real `NSScreen`; covered by manual soak test (see `SHIP_READINESS.md` #18).
- **SwiftUI views** — snapshot testing is out of scope until SwiftSnapshotTesting is added.
