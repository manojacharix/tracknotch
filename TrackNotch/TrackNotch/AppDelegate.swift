import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusMenuController: StatusMenuController?
    private var globalQuitMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        DisplayCoordinator.shared.setup()
        Task { @MainActor in
            self.statusMenuController = StatusMenuController()
            ProviderRegistry.shared.bootstrap()
        }
        // Global ⌘Q quit — lets the user kill the app even when the
        // notch dropdown is stuck in a loop and blocks the menu bar.
        globalQuitMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers == "q" else { return }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let m = globalQuitMonitor { NSEvent.removeMonitor(m); globalQuitMonitor = nil }
        ClaudeCodeMonitor.shared.stop()
        CodexMonitor.shared.stop()
        CodexUsageFetcher.shared.stop()
        CursorMonitor.shared.stop()
        ChatGPTDesktopMonitor.shared.stop()
        AntigravityMonitor.shared.stop()
        OpenAIUsageFetcher.shared.stop()
        AnthropicUsageFetcher.shared.stop()
        ClaudeRateLimitFetcher.shared.stop()
        DisplayCoordinator.shared.teardown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
