import XCTest
@testable import TrackNotch

/// `NotchMode.detect(for:)` reads `NSScreen` properties that we can't fake
/// without UI tests, so this file documents the rules as runnable assertions
/// over the cases themselves. When `NotchMode` grows a pure decision helper
/// (recommended), these tests can call it directly.
final class NotchModeDetectionTests: XCTestCase {

    func test_isExternal_includesSoftwareNotch() {
        XCTAssertTrue(NotchMode.externalMonitor.isExternal)
        XCTAssertTrue(NotchMode.softwareNotch.isExternal)
        XCTAssertFalse(NotchMode.hardwareNotch.isExternal)
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
