import SwiftUI

struct SettingsView: View {
    @StateObject private var settings = AppSettings.shared

    var body: some View {
        TabView {
            ProvidersSettingsTab()
                .tabItem { Label("Providers", systemImage: "cpu") }

            BudgetSettingsTab(settings: settings)
                .tabItem { Label("Budget", systemImage: "chart.bar") }

            DisplaySettingsTab(settings: settings)
                .tabItem { Label("Display", systemImage: "menubar.rectangle") }

            GeneralSettingsTab(settings: settings)
                .tabItem { Label("General", systemImage: "gear") }
        }
        .frame(width: 460, height: 440)
    }
}

struct ProvidersSettingsTab: View {
    @ObservedObject private var registry = ProviderRegistry.shared
    @State private var showConnectionSheet = false

    var body: some View {
        VStack(spacing: 16) {
            // Connected providers list
            if registry.connectedProviders.isEmpty {
                Spacer()
                Text("No providers connected yet")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(registry.connectedProviders, id: \.self) { provider in
                        HStack {
                            Image(provider.iconName)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20, height: 20)
                            Text(provider.displayName)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                            Spacer()
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                            Text("Connected")
                                .font(.system(size: 12, design: .rounded))
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Button("Add Provider") {
                showConnectionSheet = true
            }
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showConnectionSheet) {
            ProviderConnectionView()
        }
    }
}

struct DisplaySettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var registry = ProviderRegistry.shared

    var body: some View {
        Form {
            Section("Connected Monitors") {
                if registry.connectedProviders.isEmpty {
                    Text("No providers connected")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(registry.connectedProviders, id: \.self) { provider in
                        HStack {
                            Image(provider.iconName)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 16, height: 16)
                            Text(provider.displayName)
                                .font(.system(size: 13, design: .rounded))
                            Spacer()
                            if let usage = registry.usageMap[provider] {
                                Text("\(Int(usage.percentage))%")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(AppVersion.short)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
    }
}

struct BudgetSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Claude Arc") {
                Stepper(value: $settings.claudeContextLimit, in: 50_000...1_000_000, step: 50_000) {
                    HStack {
                        Text("Context window")
                        Spacer()
                        Text("\(settings.claudeContextLimit / 1000)K tokens")
                            .foregroundColor(.secondary)
                    }
                }
                .help("The arc shows how full your active session's context window is — same as the % Claude shows in its own UI. Current models (Sonnet, Opus) use 200K.")
            }

            Section("Subscription Plans") {
                Picker("Claude Code", selection: $settings.claudePlanTier) {
                    ForEach(ClaudePlanTier.allCases) { tier in
                        Text(tier.rawValue).tag(tier)
                    }
                }
                .help("Weekly token cap: \(settings.claudePlanTier.weeklyTokenCap.formatted())")

                Picker("ChatGPT / Codex", selection: $settings.chatGPTPlanTier) {
                    ForEach(ChatGPTPlanTier.allCases) { tier in
                        Text(tier.rawValue).tag(tier)
                    }
                }
                .help("Daily Codex tasks: \(settings.chatGPTPlanTier.dailyCodexTaskCap)")

                Picker("Cursor", selection: $settings.cursorPlanTier) {
                    ForEach(CursorPlanTier.allCases) { tier in
                        Text(tier.rawValue).tag(tier)
                    }
                }
                .help("Monthly fast requests: \(settings.cursorPlanTier.monthlyFastRequestCap)")
            }

            Section("API Monthly Budgets") {
                HStack {
                    Text("OpenAI API")
                    Spacer()
                    Text("$")
                    TextField("20", value: $settings.openAIMonthlyBudget, format: .number)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text("Anthropic API")
                    Spacer()
                    Text("$")
                    TextField("20", value: $settings.anthropicMonthlyBudget, format: .number)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
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
