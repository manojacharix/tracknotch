import AppKit
import SwiftUI

/// Opens the ProviderConnectionView in a standalone window
/// instead of a sheet on the dropdown.
@MainActor
final class ConnectionWindowController {
    static let shared = ConnectionWindowController()

    private var window: NSWindow?

    private init() {}

    func open() {
        // Open synchronously — no async hop. The earlier async-defer pattern
        // caused a race: the caller's dropdown.closeDropdown() ran FIRST
        // (resigning TrackNotch's only key window), then the deferred open
        // created the Settings window when the app had no front window —
        // and macOS refused to actually show it for an LSUIElement app.
        // Synchronous open means the Settings window becomes key BEFORE
        // the dropdown resigns, so focus transfers cleanly.
        if let existing = window, existing.isVisible {
            // For LSUIElement apps activate must come BEFORE makeKey, otherwise
            // the app stays backgrounded and the window doesn't get focus.
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        // Window exists but was closed via the system red ✕. NSWindow held it
        // alive (isReleasedWhenClosed = false) but our reference is stale —
        // clear it so we don't leak an orphaned window when we recreate below.
        if window != nil {
            window = nil
        }

        let connectionView = ProviderConnectionView()
            .environmentObject(ProviderRegistry.shared)
            .font(.system(.body, design: .rounded))

        let hostingView = NSHostingView(rootView: connectionView)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.contentView = hostingView
        win.title = "Connect Providers"
        win.center()
        win.isReleasedWhenClosed = false
        win.backgroundColor = NSColor(red: 37/255, green: 39/255, blue: 40/255, alpha: 1)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        // Sit above the notch dropdown's NotchWindow (level .mainMenu+3).
        // Without this, the dropdown's still-animating collapse visually
        // covers the freshly-opened dialog and the user perceives a lockout.
        win.level = NSWindow.Level(Int(CGWindowLevelForKey(.mainMenuWindow)) + 4)

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)

        self.window = win
    }

    func close() {
        window?.close()
        window = nil
    }
}
