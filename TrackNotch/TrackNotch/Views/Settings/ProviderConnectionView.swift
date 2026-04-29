import SwiftUI
import PhosphorSwift

/// Simplified connection view:
///  - Auto-detected: local tools already found (checkmarks, no action)
///  - API keys: paste fields for OpenAI & Anthropic
struct ProviderConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var registry = ProviderRegistry.shared

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(hex: "252728").ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                VStack(spacing: 8) {
                    Text("Connect your models")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)

                    Text("Local tools auto-connect. Paste API keys for OpenAI or Anthropic.")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundColor(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 36)
                .padding(.horizontal, 32)

                Spacer().frame(height: 24)

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        autoDetectedSection
                        apiKeySection
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }

                Spacer(minLength: 0)
            }

            // Close button
            Button {
                dismiss()
                ConnectionWindowController.shared.close()
            } label: {
                Ph.x.bold
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12, height: 12)
                    .foregroundColor(.white.opacity(0.5))
                    .padding(10)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.borderless)
            .padding(16)
        }
        .frame(width: 480, height: 520)
    }

    // MARK: - Auto-detected

    private var autoDetectedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Auto-detected", subtitle: "Local tools found on this Mac")

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

    // MARK: - API Keys

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("API Keys", subtitle: "Requires admin API keys — not regular project keys")

            VStack(spacing: 8) {
                ForEach(LLMProvider.apiKeyProviders, id: \.self) { provider in
                    APIKeyRow(provider: provider)
                }
            }
        }
    }

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.9))
            Text(subtitle)
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(.white.opacity(0.4))
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
        .onAppear {
            if ProviderAuthManager.shared.loadAPIKey(for: provider) != nil {
                isSaved = true
                apiKey = "••••••••••••••••"
            }
        }
    }

    private var placeholder: String {
        switch provider {
        case .openAIAPI:    return "sk-admin-..."
        case .anthropicAPI: return "sk-ant-admin-..."
        default:            return "paste your admin API key"
        }
    }

    private func save() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ProviderAuthManager.shared.saveAPIKey(trimmed, for: provider)
        ProviderRegistry.shared.updateConnectionState(.connected, for: provider)
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

            Text("Real 5h/7d usage. Run `claude setup-token` in terminal.")
                .font(.system(size: 10, design: .rounded))
                .foregroundColor(.white.opacity(0.35))

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
        .onAppear {
            if ProviderAuthManager.shared.loadOAuthToken(for: .claudeCode) != nil {
                isSaved = true
                token = "••••••••••••••••"
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
