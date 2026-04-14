import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        Task { @MainActor in
            DisplayCoordinator.shared.setup()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DisplayCoordinator.shared.teardown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
