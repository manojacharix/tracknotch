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
        ClaudeCodeMonitor.shared.stop()
        CodexMonitor.shared.stop()
        CursorMonitor.shared.stop()
        ChatGPTDesktopMonitor.shared.stop()
        OpenAIUsageFetcher.shared.stop()
        AnthropicUsageFetcher.shared.stop()
        ClaudeRateLimitFetcher.shared.stop()
        DisplayCoordinator.shared.teardown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
