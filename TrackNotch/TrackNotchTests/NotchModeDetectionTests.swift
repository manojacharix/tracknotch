import XCTest
@testable import TrackNotch

/// `NotchMode.detect(for:)` reads `NSScreen` properties that we can't fake
/// without UI tests, so this file documents the rules as runnable assertions
/// over the cases themselves. When `NotchMode` grows a pure decision helper
/// (recommended), these tests can call it directly.
final class NotchModeDetectionTests: XCTestCase {

    // isExternal: true only for standalone external monitors (not built-in screens)
    func test_isExternal_onlyExternalMonitor() {
        XCTAssertTrue(NotchMode.externalMonitor.isExternal)
        XCTAssertFalse(NotchMode.softwareNotch.isExternal,
                       "softwareNotch is a built-in screen; isExternal must be false")
        XCTAssertFalse(NotchMode.hardwareNotch.isExternal)
    }

    // isDrawnNotch: true when a notch/pill is software-rendered (softwareNotch or externalMonitor)
    func test_isDrawnNotch_softwareNotchAndExternal() {
        XCTAssertTrue(NotchMode.softwareNotch.isDrawnNotch)
        XCTAssertTrue(NotchMode.externalMonitor.isDrawnNotch)
        XCTAssertFalse(NotchMode.hardwareNotch.isDrawnNotch)
    }

    func test_isHardware_onlyHardware() {
        XCTAssertTrue(NotchMode.hardwareNotch.isHardware)
        XCTAssertFalse(NotchMode.softwareNotch.isHardware)
        XCTAssertFalse(NotchMode.externalMonitor.isHardware)
    }

    // TODO(sonnet):
    //
    // Extract a pure decision helper from `NotchMode.detect`:
    //
    //   static func mode(
    //       hasAuxLeft: Bool,
    //       hasSafeAreaTop: Bool,
    //       localizedName: String
    //   ) -> NotchMode
    //
    // Then pin these cases:
    //
    //   - hasAuxLeft=true, anything → .hardwareNotch
    //   - hasSafeAreaTop=true, name="Built-in Retina" → .hardwareNotch
    //   - hasAuxLeft=false, hasSafeAreaTop=false, name="Studio Display" → .externalMonitor
    //   - hasAuxLeft=false, hasSafeAreaTop=false, name="Built-in Liquid Retina" → .softwareNotch
    //
    // The current `detect(for:)` ties the decision to NSScreen, which makes it
    // un-testable on CI. The helper above keeps the same logic but takes
    // primitive inputs.
}
