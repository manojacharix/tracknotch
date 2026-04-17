import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        DisplayCoordinator.shared.setup()
        Task { @MainActor in
            ProviderRegistry.shared.bootstrap()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DisplayCoordinator.shared.teardown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
