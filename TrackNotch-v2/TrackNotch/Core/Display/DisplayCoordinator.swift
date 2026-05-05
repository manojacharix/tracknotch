import AppKit
import SwiftUI
import Combine

/// Central coordinator that detects display configuration and sets up
/// the correct notch window (hardware or software) on each screen.
@MainActor
final class DisplayCoordinator: ObservableObject {
    static let shared = DisplayCoordinator()

    /// Keyed by CGDirectDisplayID so NSScreen object churn (clamshell, reconnect)
    /// doesn't create duplicate windows for the same physical display.
    private var notchWindows: [UInt32: NotchWindow] = [:]
    private var screenObserver: Any?
    private var wakeObserver: Any?
    private var screenChangeWork: DispatchWorkItem?
    private var settingsCancellable: AnyCancellable?

    private init() {}

    // MARK: - Setup

    func setup() {
        if AppSettings.shared.isNotchEnabled {
            setupWindows()
        }
        observeScreenChanges()
        observeSettings()
    }

    func teardown() {
        closeAllWindows()
        screenChangeWork?.cancel()
        settingsCancellable?.cancel()
        settingsCancellable = nil
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private func closeAllWindows() {
        notchWindows.values.forEach { $0.close() }
        notchWindows.removeAll()
    }

    /// Collapse any currently-open dropdown across all NotchWindow instances.
    /// Used preemptively when a competing window (e.g. the menu bar dropdown
    /// or its eventual Settings dialog) is about to open — otherwise the
    /// half-second SwiftUI collapse animation lets the dropdown visually
    /// occlude the new window.
    func collapseAnyOpenDropdown() {
        notchWindows.values.forEach { $0.forceCollapseDropdownIfOpen() }
    }

    private func observeSettings() {
        // @Published emits in willSet, so the stored value still reads as the
        // *old* value while this sink runs. We must drive setup/teardown off
        // the closure parameter, not a fresh read of AppSettings.
        settingsCancellable = AppSettings.shared.$isNotchEnabled
            .removeDuplicates()
            .dropFirst()
            // willSet → main-queue hop so setupWindows reads the post-set value.
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.setupWindows()
                } else {
                    self.closeAllWindows()
                }
            }
    }

    // MARK: - Window Management

    private func displayID(for screen: NSScreen) -> UInt32? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }

    private func setupWindows() {
        guard AppSettings.shared.isNotchEnabled else { return }
        for screen in NSScreen.screens {
            guard let id = displayID(for: screen), notchWindows[id] == nil else { continue }
            addWindow(id: id, for: screen)
        }
    }

    private func addWindow(id: UInt32, for screen: NSScreen) {
        let mode = NotchMode.detect(for: screen)
        let window = NotchWindow(screen: screen, mode: mode)
        window.show()
        notchWindows[id] = window
        #if DEBUG
        print("[Display] Created \(mode) window for display \(id)")
        #endif
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Debounce — macOS fires this multiple times during display transitions
            self?.screenChangeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in self?.handleScreenChange() }
            }
            self?.screenChangeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }

        // Refresh hover monitors and tracking areas after sleep/wake — the
        // global event monitor context goes stale during sleep.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Wait 1s for display stack to fully settle after wake
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Task { @MainActor in self?.handleWake() }
            }
        }
    }

    private func handleWake() {
        handleScreenChange()
        notchWindows.values.forEach { $0.refreshAfterWake() }
    }

    private func handleScreenChange() {
        // If the notch is disabled, drop any stragglers and stop. We still need
        // the observer wired so that re-enabling reflects the current display set.
        guard AppSettings.shared.isNotchEnabled else {
            closeAllWindows()
            return
        }
        let currentScreens = NSScreen.screens
        let activeIDs = Set(currentScreens.compactMap { displayID(for: $0) })

        // Remove windows for disconnected displays
        for id in notchWindows.keys where !activeIDs.contains(id) {
            #if DEBUG
            print("[Display] Removing window for disconnected display \(id)")
            #endif
            notchWindows[id]?.close()
            notchWindows.removeValue(forKey: id)
        }

        // Add new windows and reposition existing ones
        for screen in currentScreens {
            guard let id = displayID(for: screen) else { continue }
            if let existingWindow = notchWindows[id] {
                // Reposition to match updated screen coordinates
                existingWindow.reposition(to: screen)
            } else {
                addWindow(id: id, for: screen)
            }
        }
    }
}
