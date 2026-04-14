import SwiftUI

/// Sheet opened from the dropdown "settings" button.
/// Two tabs: Subscription (session cookie) and API Key.
struct ProviderConnectionView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Connect Providers")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            TabView {
                SubscriptionConnectionTab()
                    .tabItem { Label("Subscription", systemImage: "person.crop.circle") }

                APIKeyConnectionTab()
                    .tabItem { Label("API Key", systemImage: "key") }
            }
        }
        .frame(width: 420, height: 460)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Subscription Tab

private struct SubscriptionConnectionTab: View {
    private let providers: [LLMProvider] = [.claude, .chatGPT, .cursor, .antigravity]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(providers, id: \.self) { provider in
                    SubscriptionConnectionRow(provider: provider)
                }
            }
            .padding(20)
        }
    }
}

private struct SubscriptionConnectionRow: View {
    let provider: LLMProvider
    // In production this would read from ProviderRegistry / Keychain
    @State private var connectionState: ProviderConnectionState = .notConfigured

    var body: some View {
        HStack(spacing: 12) {
            Image(provider.iconName)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                Text(connectionState.displayText)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(stateColor)
            }

            Spacer()

            Button(connectionState.isConnected ? "Disconnect" : "Connect") {
                // Placeholder — real auth flow per provider in V1 implementation
            }
            .buttonStyle(.bordered)
            .font(.system(size: 12, design: .rounded))
            .tint(connectionState.isConnected ? .red : provider.accentColor)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    private var stateColor: Color {
        switch connectionState {
        case .connected:      return .green
        case .error:          return .red
        case .sessionExpired: return .orange
        default:              return .secondary
        }
    }
}

// MARK: - API Key Tab

private struct APIKeyConnectionTab: View {
    private let providers: [LLMProvider] = [.openAIAPI, .claude]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(providers, id: \.self) { provider in
                    APIKeyConnectionRow(provider: provider)
                }
            }
            .padding(20)
        }
    }
}

private struct APIKeyConnectionRow: View {
    let provider: LLMProvider
    @State private var apiKey: String = ""
    @State private var isRevealed: Bool = false
    @State private var connectionState: ProviderConnectionState = .notConfigured

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(provider.iconName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                    Text(connectionState.displayText)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundColor(stateColor)
                }

                Spacer()

                if connectionState.isConnected {
                    Button("Disconnect") {
                        apiKey = ""
                        connectionState = .notConfigured
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 12, design: .rounded))
                    .tint(.red)
                }
            }

            if !connectionState.isConnected {
                HStack {
                    if isRevealed {
                        TextField("API Key", text: $apiKey)
                    } else {
                        SecureField("API Key", text: $apiKey)
                    }

                    Button {
                        isRevealed.toggle()
                    } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)

                    Button("Save") {
                        // Placeholder — store in Keychain, validate key in V1 implementation
                        if !apiKey.isEmpty {
                            connectionState = .connected
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .font(.system(size: 12, design: .rounded))
                    .tint(provider.accentColor)
                    .disabled(apiKey.isEmpty)
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    private var stateColor: Color {
        switch connectionState {
        case .connected: return .green
        case .error:     return .red
        default:         return .secondary
        }
    }
}

