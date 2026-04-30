import SwiftUI

/// SwiftUI → AppKit channel: lets the SwiftUI dropdown view publish the measured
/// content height of the expanded dropdown so `NotchWindow.interactiveContentRectInView`
/// can compute a tight, static hit-test rect without live frame measurement.
@MainActor
final class DropdownFrameReporter: ObservableObject {
    /// Height of the dropdown content area (excluding the pill row itself).
    /// 0 until the first layout pass after open.
    @Published var dropdownContentHeight: CGFloat = 0
}
