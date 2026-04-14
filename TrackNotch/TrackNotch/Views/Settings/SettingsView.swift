import SwiftUI

struct SettingsView: View {
    @StateObject private var settings = AppSettings.shared

    var body: some View {
        TabView {
            ProvidersSettingsTab()
                .tabItem { Label("Providers", systemImage: "cpu") }

            DisplaySettingsTab(settings: settings)
                .tabItem { Label("Display", systemImage: "menubar.rectangle") }

            GeneralSettingsTab(settings: settings)
                .tabItem { Label("General", systemImage: "gear") }
        }
        .frame(width: 460, height: 400)
    }
}

struct ProvidersSettingsTab: View {
    var body: some View {
        VStack {
            Text("Connect your providers")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
            Text("Coming soon")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DisplaySettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Idle Behaviour") {
                Picker("Collapse after", selection: $settings.idleCollapseTimeout) {
                    ForEach(IdleTimeout.allCases) { timeout in
                        Text(timeout.rawValue).tag(timeout)
                    }
                }
            }
        }
        .padding()
    }
}

struct GeneralSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            }
        }
        .padding()
    }
}
