import AppKit
import Combine

/// Owns the menu bar `NSStatusItem` and its dropdown `NSMenu`. The menu is the
/// only UI surface the user has when the notch pill is disabled, so it must
/// always be present while the app is running.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let toggleNotchItem = NSMenuItem()
    private var settingsCancellable: AnyCancellable?

    override init() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
        statusItem.menu = buildMenu()
        observeSettings()
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: - Setup

    private func configureButton() {
        guard let button = statusItem.button else { return }
        let image = NSImage(named: "StatusBarIcon")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        button.toolTip = "TrackNotch"
        button.setAccessibilityLabel("TrackNotch")
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        toggleNotchItem.action = #selector(toggleNotch)
        toggleNotchItem.target = self
        refreshToggleNotchTitle()
        menu.addItem(toggleNotchItem)

        menu.addItem(.separator())

        let versionItem = NSMenuItem(
            title: "TrackNotch v\(AppVersion.short)",
            action: nil,
            keyEquivalent: ""
        )
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        menu.addItem(.separator())

        let bugItem = NSMenuItem(
            title: "Report a Bug…",
            action: #selector(reportBug),
            keyEquivalent: ""
        )
        bugItem.target = self
        menu.addItem(bugItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit TrackNotch",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - State

    private func observeSettings() {
        settingsCancellable = AppSettings.shared.$isNotchEnabled
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.refreshToggleNotchTitle()
            }
    }

    private func refreshToggleNotchTitle() {
        toggleNotchItem.title = AppSettings.shared.isNotchEnabled ? "Disable Notch" : "Enable Notch"
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        // Defensive: ensure title reflects current state in case the publisher
        // missed an update (e.g. settings changed while menu was building).
        refreshToggleNotchTitle()
        // Belt-and-suspenders: collapse any open notch dropdown so the menu
        // and any dialog opened from it can layer cleanly. This is redundant
        // with openSettings()'s own collapse call but harmless if it fires.
        DisplayCoordinator.shared.collapseAnyOpenDropdown()
    }

    // MARK: - Actions

    @objc private func openSettings() {
        // Open the same window the pill dropdown uses, so users have one
        // settings surface regardless of how they got there. The async hop
        // is defense-in-depth — @objc selectors don't enforce MainActor at
        // compile time, so we make the main-thread guarantee explicit.
        DispatchQueue.main.async {
            // Collapse the notch dropdown if it happens to be open. menuWillOpen
            // doesn't fire reliably for NSStatusItem.menu = X, and resignKey
            // doesn't always trigger when the dialog grabs key — so do it here
            // at the deterministic moment Settings is actually being opened.
            DisplayCoordinator.shared.collapseAnyOpenDropdown()
            ConnectionWindowController.shared.open()
        }
    }

    @objc private func toggleNotch() {
        AppSettings.shared.isNotchEnabled.toggle()
    }

    @objc private func reportBug() {
        NSWorkspace.shared.open(URL(string: "https://github.com/manojacharix/tracknotch/issues")!)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
