import SwiftUI

@main
struct TrackNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .font(.system(.body, design: .rounded))
        }
    }
}
