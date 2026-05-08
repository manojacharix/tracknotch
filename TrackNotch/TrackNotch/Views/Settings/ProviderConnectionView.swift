import SwiftUI

/// Simplified connection view:
///  - Auto-detected: local tools already found (checkmarks, no action)
///  - API keys: paste fields for OpenAI & Anthropic
struct ProviderConnectionView: View {
    @ObservedObject private var registry = ProviderRegistry.shared
    @ObservedObject private var updater = UpdateChecker.shared

    @State private var headerVisible = false
    @State private var section1Visible = false
    @State private var section2Visible = false
    @State private var section3Visible = false

    var body: some View {
        ZStack {
            Color(hex: "252728").ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.top, 28)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 20)
                    .opacity(headerVisible ? 1 : 0)
                    .offset(y: headerVisible ? 0 : 10)

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        autoDetectedSection
                            .opacity(section1Visible ? 1 : 0)
                            .offset(y: section1Visible ? 0 : 10)
                        apiKeySection
                            .opacity(section2Visible ? 1 : 0)
                            .offset(y: section2Visible ? 0 : 10)
                        reportBugSection
                            .opacity(section3Visible ? 1 : 0)
                            .offset(y: section3Visible ? 0 : 10)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
        }
        .frame(width: 480, height: 520)
        .onAppear {
            withAnimation(.easeOut(duration: 0.22)) { headerVisible = true }
            withAnimation(.easeOut(duration: 0.22).delay(0.07)) { section1Visible = true }
            withAnimation(.easeOut(duration: 0.22).delay(0.12)) { section2Visible = true }
            withAnimation(.easeOut(duration: 0.22).delay(0.17)) { section3Visible = true }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(spacing: 6) {
                Text("TrackNotch")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                Text("Version \(AppVersion.short)")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.white.opacity(0.4))
            }
            .onAppear { UpdateChecker.shared.check() }

            Text("Track your LLM usage in real time — locally and privately. Costs and quotas across Claude, OpenAI, Cursor, and more, surfaced right at the notch.")
                .font(.system(size: 12, design: .rounded))
                .foregroundColor(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.top, 4)

            updateBadge
                .padding(.top, 8)
        }
    }

    // MARK: - Update badge

    @ViewBuilder
    private var updateBadge: some View {
        switch updater.state {
        case .available(let version, let url):
            Button(action: { NSWorkspace.shared.open(url) }) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Color(hex: "b4e50d"))
                    Text("Update to v\(version)")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(Color(hex: "b4e50d"))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(hex: "b4e50d").opacity(0.15))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color(hex: "b4e50d").opacity(0.35), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.borderless)
        case .checking:
            EmptyView()
        default:
            EmptyView()
        }
    }

    // MARK: - Sections

    private var autoDetectedSection: some View {
        SettingsSection(title: "Local tools",
                subtitle: "Auto-detected on this Mac") {
            VStack(spacing: 8) {
                ForEach(LLMProvider.localProviders, id: \.self) { provider in
                    LocalProviderRow(
                        provider: provider,
                        isConnected: registry.connectionStates[provider]?.isConnected == true
                    )
                }
            }
        }
    }

    private var reportBugSection: some View {
        SettingsSection(title: "Support", subtitle: "Something broken?") {
            Button(action: {
                NSWorkspace.shared.open(URL(string: "https://github.com/manojacharix/tracknotch/issues")!)
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "ladybug")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.7))
                    Text("Report a Bug")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.85))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.35))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
            }
            .buttonStyle(.borderless)
        }
    }

    private var apiKeySection: some View {
        SettingsSection(title: "API providers",
                subtitle: "Paste an API key to track spend") {
            VStack(spacing: 8) {
                ForEach(LLMProvider.apiKeyProviders, id: \.self) { provider in
                    APIKeyRow(provider: provider)
                }
            }
        }
    }
}

// MARK: - Section header

private struct SettingsSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))
                    .tracking(0.6)
                Text(subtitle)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.white.opacity(0.35))
            }
            content()
        }
    }
}

// MARK: - Local Provider Row

private struct LocalProviderRow: View {
    let provider: LLMProvider
    let isConnected: Bool
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(provider.iconName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.9))
                    Text(isConnected ? "Connected" : "Not installed")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundColor(isConnected ? Color(hex: "b4e50d") : .white.opacity(0.35))
                }

                Spacer()

                if isConnected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Color(hex: "b4e50d"))
                        .font(.system(size: 16))
                } else {
                    Image(systemName: "circle")
                        .foregroundColor(.white.opacity(0.2))
                        .font(.system(size: 16))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            // Plan picker for connected providers that have plan tiers
            if isConnected && hasPlanPicker {
                Divider().background(Color.white.opacity(0.08))
                    .padding(.horizontal, 12)
                planPicker
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }

            // OAuth token for Claude Code rate-limit tracking
            if isConnected && provider == .claudeCode {
                Divider().background(Color.white.opacity(0.08))
                    .padding(.horizontal, 12)
                OAuthTokenRow()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    private var hasPlanPicker: Bool {
        [.claudeCode, .cursorIDE, .codex, .chatGPTDesktop].contains(provider)
    }

    @ViewBuilder
    private var planPicker: some View {
        HStack {
            Text("Plan")
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(.white.opacity(0.5))
            Spacer()
            switch provider {
            case .claudeCode:
                planMenu(selection: $settings.claudePlanTier)
            case .cursorIDE:
                planMenu(selection: $settings.cursorPlanTier)
            case .codex, .chatGPTDesktop:
                planMenu(selection: $settings.chatGPTPlanTier)
            default:
                EmptyView()
            }
        }
    }

    private func planMenu<T: CaseIterable & Identifiable & RawRepresentable & Hashable>(
        selection: Binding<T>
    ) -> some View where T.RawValue == String, T.AllCases: RandomAccessCollection {
        Menu {
            ForEach(T.allCases) { tier in
                Button(tier.rawValue) { selection.wrappedValue = tier }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selection.wrappedValue.rawValue)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.85))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.white.opacity(0.4))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.1))
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - API Key Row

private struct APIKeyRow: View {
    let provider: LLMProvider

    @State private var apiKey: String = ""
    @State private var isSaved: Bool = false
    @State private var isRevealed: Bool = false
    @State private var errorMessage: String?
    @State private var isInitialized: Bool = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(provider.iconName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)

                Text(provider.displayName)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 100, alignment: .leading)

                Group {
                    if isRevealed || isSaved {
                        TextField(placeholder, text: $apiKey)
                    } else {
                        SecureField(placeholder, text: $apiKey)
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
                .disabled(isSaved)
                .onSubmit { save() }

                if isSaved {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Color(hex: "b4e50d"))
                        .font(.system(size: 14))
                    Button(action: disconnect) {
                        Image(systemName: "xmark.circle")
                            .foregroundColor(.white.opacity(0.5))
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button {
                        isRevealed.toggle()
                    } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                            .foregroundColor(.white.opacity(0.4))
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                    Button(action: save) {
                        Text("Save")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(apiKey.isEmpty ? .white.opacity(0.3) : .white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(apiKey.isEmpty ? Color.white.opacity(0.06) : Color.white.opacity(0.18))
                            )
                    }
                    .buttonStyle(.borderless)
                    .disabled(apiKey.isEmpty)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )

            if let help = providerHelp {
                HStack {
                    Text(help)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.white.opacity(0.4))
                    Spacer()
                }
                .padding(.horizontal, 4)
            }

            if let err = errorMessage {
                HStack {
                    Text(err)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundColor(Color(hex: "fb4141"))
                    Spacer()
                }
                .padding(.horizontal, 4)
            }
        }
        .disabled(!isInitialized)
        .opacity(isInitialized ? 1 : 0.5)
        .onAppear {
            if ProviderAuthManager.shared.loadAPIKey(for: provider) != nil {
                isSaved = true
                apiKey = "••••••••••••••••"
            }
            isInitialized = true
        }
    }

    private var placeholder: String {
        switch provider {
        case .openAIAPI:    return "sk-admin-..."
        case .anthropicAPI: return "sk-ant-admin-..."
        default:            return "paste your admin API key"
        }
    }

    /// Provider-specific tooltip shown below the API key field.
    fileprivate var providerHelp: String? {
        switch provider {
        case .anthropicAPI: return "Requires an Admin key (sk-ant-admin-…). Cost tracking is org-level only."
        default:            return nil
        }
    }

    private func save() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if provider == .anthropicAPI && !trimmed.hasPrefix("sk-ant-admin") {
            errorMessage = "Admin key required (sk-ant-admin-…). Regular API keys can't fetch cost."
            return
        }
        ProviderAuthManager.shared.saveAPIKey(trimmed, for: provider)
        ProviderRegistry.shared.updateConnectionState(.connected, for: provider)
        // Seed an empty usage entry so the dropdown pill renders immediately,
        // before the first fetcher poll completes.
        ProviderRegistry.shared.seedEmptyUsageIfNeeded(for: provider)
        isSaved = true
        apiKey = "••••••••••••••••"
        errorMessage = nil

        // Kick off usage fetcher
        switch provider {
        case .openAIAPI:    OpenAIUsageFetcher.shared.start()
        case .anthropicAPI: AnthropicUsageFetcher.shared.start()
        default:            break
        }
    }

    private func disconnect() {
        ProviderAuthManager.shared.disconnect(provider)
        ProviderRegistry.shared.updateConnectionState(.notConfigured, for: provider)
        switch provider {
        case .openAIAPI:    OpenAIUsageFetcher.shared.stop()
        case .anthropicAPI: AnthropicUsageFetcher.shared.stop()
        default:            break
        }
        isSaved = false
        apiKey = ""
    }
}

// MARK: - OAuth Token Row (Claude Code rate-limit tracking)

private struct OAuthTokenRow: View {
    @State private var token: String = ""
    @State private var isSaved: Bool = false
    @State private var isRevealed: Bool = false
    @State private var showHelp: Bool = false
    @State private var isInitialized: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Rate-limit tracking")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                if isSaved {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Color(hex: "b4e50d"))
                        .font(.system(size: 12))
                }
            }

            Text("Real 5h/7d usage from Anthropic rate-limit headers.")
                .font(.system(size: 10, design: .rounded))
                .foregroundColor(.white.opacity(0.35))

            // Expandable how-to. Collapsed by default to keep the row compact.
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showHelp.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showHelp ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text("How do I get an OAuth token?")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                }
                .foregroundColor(.white.opacity(0.55))
            }
            .buttonStyle(.borderless)

            if showHelp {
                VStack(alignment: .leading, spacing: 4) {
                    helpStep("1.", "Install Claude Code if you haven't:",
                             code: "npm install -g @anthropic-ai/claude-code")
                    helpStep("2.", "Run this in any terminal:",
                             code: "claude setup-token")
                    helpStep("3.", "Open the URL it prints, sign in to your Anthropic account, and approve access.")
                    helpStep("4.", "Copy the token (starts with sk-ant-oat01-…) back into the terminal — it prints back as confirmation.")
                    helpStep("5.", "Paste that same token into the field below and hit Save.")

                    Text("Stored in your macOS Keychain. Used only for a 1-token probe call every ~30s to read 5h / 7d rate-limit headers — no message content is sent.")
                        .font(.system(size: 9, design: .rounded))
                        .foregroundColor(.white.opacity(0.35))
                        .padding(.top, 2)
                }
                .padding(.leading, 12)
                .padding(.vertical, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: 8) {
                Group {
                    if isRevealed || isSaved {
                        TextField("sk-ant-oat01-...", text: $token)
                    } else {
                        SecureField("sk-ant-oat01-...", text: $token)
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
                .disabled(isSaved)
                .onSubmit { save() }

                if isSaved {
                    Button(action: disconnect) {
                        Image(systemName: "xmark.circle")
                            .foregroundColor(.white.opacity(0.5))
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button {
                        isRevealed.toggle()
                    } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                            .foregroundColor(.white.opacity(0.4))
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)

                    Button(action: save) {
                        Text("Save")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundColor(token.isEmpty ? .white.opacity(0.3) : .white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(token.isEmpty ? Color.white.opacity(0.06) : Color.white.opacity(0.18))
                            )
                    }
                    .buttonStyle(.borderless)
                    .disabled(token.isEmpty)
                }
            }
        }
        .disabled(!isInitialized)
        .opacity(isInitialized ? 1 : 0.5)
        .onAppear {
            if ProviderAuthManager.shared.loadOAuthToken(for: .claudeCode) != nil {
                isSaved = true
                token = "••••••••••••••••"
            }
            isInitialized = true
        }
    }

    @ViewBuilder
    private func helpStep(_ num: String, _ text: String, code: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 6) {
                Text(num)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
                    .frame(width: 12, alignment: .leading)
                Text(text)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let code {
                CopyableCode(code: code)
                    .padding(.leading, 18)
            }
        }
    }

    private func save() {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ProviderAuthManager.shared.saveOAuthToken(trimmed, for: .claudeCode)
        isSaved = true
        token = "••••••••••••••••"

        // Start rate-limit fetcher and re-wire Claude Code usage tracking
        ClaudeRateLimitFetcher.shared.start()
        ProviderRegistry.shared.startClaudeUsageTracking(monitor: ClaudeCodeMonitor.shared)
    }

    private func disconnect() {
        ProviderAuthManager.shared.disconnectOAuth(.claudeCode)
        ClaudeRateLimitFetcher.shared.stop()
        // Fall back to local JSONL estimate
        ProviderRegistry.shared.startClaudeUsageTracking(monitor: ClaudeCodeMonitor.shared)
        isSaved = false
        token = ""
    }
}

/// Copy-to-clipboard chip with ephemeral "Copied" confirmation in place of
/// the copy icon for ~1.5s after a successful copy.
private struct CopyableCode: View {
    let code: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            Text(code)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.08))
                )
                .textSelection(.enabled)
            Button(action: copy) {
                Group {
                    if copied {
                        Text("Copied")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundColor(Color(hex: "b4e50d"))
                    } else {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                .frame(minWidth: 12, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(code, forType: .string)
        withAnimation(.easeInOut(duration: 0.15)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.15)) { copied = false }
        }
    }
}
