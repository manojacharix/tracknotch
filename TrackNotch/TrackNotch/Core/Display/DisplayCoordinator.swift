import AppKit
import SwiftUI
import Combine

/// Central coordinator that detects display configuration and sets up
/// the correct notch window (hardware or software) on each screen.
@MainActor
final class DisplayCoordinator: ObservableObject {
    static let shared = DisplayCoordinator()

    private var notchWindows: [NSScreen: NotchWindow] = [:]
    private var screenObserver: Any?

    private init() {}

    // MARK: - Setup

    func setup() {
        setupWindows()
        observeScreenChanges()
    }

    func teardown() {
        notchWindows.values.forEach { $0.close() }
        notchWindows.removeAll()
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Window Management

    private func setupWindows() {
        // In clamshell mode, NSScreen.screens may momentarily include the built-in display.
        // Only create one window per unique display ID.
        var seenDisplayIDs = Set<UInt32>()
        for screen in NSScreen.screens {
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
            guard seenDisplayIDs.insert(displayID).inserted else { continue }
            addWindow(for: screen)
        }
    }

    private func addWindow(for screen: NSScreen) {
        let mode = NotchMode.detect(for: screen)
        let window = NotchWindow(screen: screen, mode: mode)
        window.show()
        notchWindows[screen] = window
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenChange()
            }
        }
    }

    private func handleScreenChange() {
        // Remove windows for disconnected screens
        for screen in notchWindows.keys {
            if !NSScreen.screens.contains(screen) {
                notchWindows[screen]?.close()
                notchWindows.removeValue(forKey: screen)
            }
        }

        // Add windows for new screens
        for screen in NSScreen.screens {
            if notchWindows[screen] == nil {
                addWindow(for: screen)
            }
        }
    }
}
