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
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let connectionView = ProviderConnectionView()
            .environmentObject(ProviderRegistry.shared)

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

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = win
    }

    func close() {
        window?.close()
        window = nil
    }
}
