import SwiftUI
import PhosphorSwift

// MARK: - Navigation

enum ConnectionScreen {
    case pick
    case subscription
    case apiKey
}

// MARK: - Container

struct ProviderConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var screen: ConnectionScreen = .pick

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(hex: "252728").ignoresSafeArea()

            Group {
                switch screen {
                case .pick:
                    OnboardingPickView(onConnect: { choice in
                        withAnimation(.easeInOut(duration: 0.25)) {
                            screen = choice == .apiKey ? .apiKey : .subscription
                        }
                    })
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading),
                        removal: .move(edge: .leading)
                    ))

                case .subscription:
                    SubscriptionSelectionView(onBack: {
                        withAnimation(.easeInOut(duration: 0.25)) { screen = .pick }
                    })
                    .transition(.move(edge: .trailing))

                case .apiKey:
                    APIConnectionView(onBack: {
                        withAnimation(.easeInOut(duration: 0.25)) { screen = .pick }
                    })
                    .transition(.move(edge: .trailing))
                }
            }

            // Close button (always visible)
            Button { dismiss() } label: {
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
}

// MARK: - Screen 1: Pick type

private struct OnboardingPickView: View {
    let onConnect: (ConnectionScreen) -> Void
    @State private var selected: ConnectionScreen? = nil

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Title + subtitle
            VStack(spacing: 10) {
                Text("Connect your models")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)

                Text("Choose your preferred method to connect with\nyour models and track them")
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .foregroundColor(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)

            Spacer().frame(height: 36)

            // Two tiles
            HStack(spacing: 12) {
                PickTile(
                    label: "API Key",
                    iconName: "key.fill",
                    isSystemIcon: true,
                    accentColor: Color(hex: "b4e50d"),
                    baseTint: Color(hex: "b4e50d").opacity(0.16),
                    isSelected: selected == .apiKey
                ) { selected = .apiKey }

                PickTile(
                    label: "Subscription",
                    iconName: "person.crop.circle.fill",
                    isSystemIcon: true,
                    accentColor: Color(hex: "ff9b2f"),
                    baseTint: Color.white.opacity(0.08),
                    isSelected: selected == .subscription
                ) { selected = .subscription }
            }
            .padding(.horizontal, 40)

            Spacer()

            // CTA
            ConnectButton(
                label: "Connect",
                isEnabled: selected != nil
            ) {
                if let s = selected { onConnect(s) }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PickTile: View {
    let label: String
    let iconName: String
    let isSystemIcon: Bool
    let accentColor: Color
    let baseTint: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                if isSystemIcon {
                    Image(systemName: iconName)
                        .font(.system(size: 28))
                        .foregroundColor(isSelected ? accentColor : .white.opacity(0.7))
                } else {
                    Image(iconName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                        .foregroundColor(isSelected ? accentColor : .white.opacity(0.7))
                }

                Text(label)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium, design: .rounded))
                    .foregroundColor(isSelected ? .white : .white.opacity(0.65))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 100)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? accentColor.opacity(0.16) : baseTint)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(isSelected ? accentColor : Color.clear, lineWidth: 2)
                    )
            )
        }
        .buttonStyle(.borderless)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - Screen 2a: Subscription selection

private struct SubscriptionSelectionView: View {
    let onBack: () -> Void

    private let providers: [LLMProvider] = [.cursor, .chatGPT, .claude, .antigravity]
    @State private var selected: LLMProvider? = nil
    @State private var connectedProviders: Set<LLMProvider> = []
    @State private var connectingProvider: LLMProvider? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Back button
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Ph.caretLeft.bold
                            .resizable()
                            .scaledToFit()
                            .frame(width: 10, height: 10)
                        Text("Back")
                            .font(.system(size: 13, design: .rounded))
                    }
                    .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            Spacer()

            // Title + subtitle
            VStack(spacing: 10) {
                Text("Connect your subscription")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)

                Text("Choose your preferred method to connect\nwith your subscriptions")
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .foregroundColor(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)

            Spacer().frame(height: 28)

            // 2×2 provider grid
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(providers, id: \.self) { provider in
                    SubscriptionProviderTile(
                        provider: provider,
                        isSelected: selected == provider,
                        isConnected: connectedProviders.contains(provider),
                        isConnecting: connectingProvider == provider
                    ) {
                        selected = provider
                    } onDisconnect: {
                        connectedProviders.remove(provider)
                        if selected == provider { selected = nil }
                    }
                }
            }
            .padding(.horizontal, 40)

            Spacer()

            // CTA
            Group {
                if let s = selected, connectedProviders.contains(s) {
                    ConnectButton(label: "Done", isEnabled: true) { onBack() }
                } else {
                    ConnectButton(
                        label: connectingProvider != nil ? "Opening browser…" : "Connect",
                        isEnabled: selected != nil && connectingProvider == nil
                    ) {
                        guard let provider = selected else { return }
                        connectingProvider = provider
                        NSWorkspace.shared.open(provider.loginURL)
                        // Show "Mark as connected" after browser opens
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 40)

            // After browser opens — manual confirmation
            if let provider = connectingProvider, !connectedProviders.contains(provider) {
                Button("Mark \(provider.displayName) as connected") {
                    connectedProviders.insert(provider)
                    connectingProvider = nil
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12, design: .rounded))
                .foregroundColor(provider.accentColor)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SubscriptionProviderTile: View {
    let provider: LLMProvider
    let isSelected: Bool
    let isConnected: Bool
    let isConnecting: Bool
    let onSelect: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 8) {
                    Image(provider.iconName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)

                    Text(provider.displayName)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(isSelected ? 1 : 0.7))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 100)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(
                                    isSelected ? provider.accentColor : Color.clear,
                                    lineWidth: 2
                                )
                        )
                )

                // Connected badge
                if isConnected {
                    ZStack {
                        Circle()
                            .fill(Color(hex: "b4e50d"))
                            .frame(width: 18, height: 18)
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.black)
                    }
                    .padding(6)
                }

                // Disconnect × when connected + selected
                if isConnected && isSelected {
                    Button(action: onDisconnect) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .buttonStyle(.borderless)
                    .padding(6)
                }
            }
        }
        .buttonStyle(.borderless)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - Screen 2b: API connection

private struct APIConnectionView: View {
    let onBack: () -> Void

    private let providers: [LLMProvider] = [.claude, .openAIAPI]
    @State private var apiKeys: [LLMProvider: String] = [:]
    @State private var savedKeys: Set<LLMProvider> = []
    @State private var revealedKeys: Set<LLMProvider> = []
    @State private var errorProviders: Set<LLMProvider> = []

    var body: some View {
        VStack(spacing: 0) {
            // Back button
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Ph.caretLeft.bold
                            .resizable()
                            .scaledToFit()
                            .frame(width: 10, height: 10)
                        Text("Back")
                            .font(.system(size: 13, design: .rounded))
                    }
                    .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            Spacer()

            // Title + subtitle
            VStack(spacing: 10) {
                Text("Connect your API")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)

                Text("Paste your API keys below to start\ntracking your usage and spend")
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .foregroundColor(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)

            Spacer().frame(height: 28)

            // API key rows
            VStack(spacing: 10) {
                ForEach(providers, id: \.self) { provider in
                    APIKeyRow(
                        provider: provider,
                        key: Binding(
                            get: { apiKeys[provider] ?? "" },
                            set: { apiKeys[provider] = $0 }
                        ),
                        isSaved: savedKeys.contains(provider),
                        isRevealed: revealedKeys.contains(provider),
                        isError: errorProviders.contains(provider),
                        onToggleReveal: {
                            if revealedKeys.contains(provider) {
                                revealedKeys.remove(provider)
                            } else {
                                revealedKeys.insert(provider)
                            }
                        },
                        onSave: {
                            let key = apiKeys[provider] ?? ""
                            guard !key.isEmpty else { return }
                            // Placeholder: validate + store in Keychain
                            savedKeys.insert(provider)
                            errorProviders.remove(provider)
                        },
                        onDisconnect: {
                            savedKeys.remove(provider)
                            apiKeys[provider] = ""
                        }
                    )
                }
            }
            .padding(.horizontal, 40)

            Spacer()

            ConnectButton(
                label: savedKeys.count == providers.count ? "Done" : "Save",
                isEnabled: apiKeys.values.contains(where: { !$0.isEmpty }) || !savedKeys.isEmpty
            ) {
                // Save all unsaved keys
                for provider in providers {
                    let key = apiKeys[provider] ?? ""
                    if !key.isEmpty && !savedKeys.contains(provider) {
                        savedKeys.insert(provider)
                    }
                }
                if savedKeys.count == providers.count { onBack() }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct APIKeyRow: View {
    let provider: LLMProvider
    @Binding var key: String
    let isSaved: Bool
    let isRevealed: Bool
    let isError: Bool
    let onToggleReveal: () -> Void
    let onSave: () -> Void
    let onDisconnect: () -> Void

    var pillBg: Color {
        if isError { return Color(hex: "fef0f0") }
        if isSaved { return Color(hex: "f0ffd8") }
        return .white
    }

    var body: some View {
        HStack(spacing: 0) {
            // Model name pill
            Text(provider.displayName)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(.black)
                .padding(.horizontal, 10)
                .frame(width: 100, height: 35)
                .background(pillBg)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            // Key input
            Group {
                if isRevealed || isSaved {
                    TextField("paste your API key", text: $key)
                } else {
                    SecureField("paste your API key", text: $key)
                }
            }
            .font(.system(size: 13, design: .monospaced))
            .foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .frame(height: 35)
            .disabled(isSaved)
            .onSubmit { if !key.isEmpty { onSave() } }

            Spacer(minLength: 0)

            // Trailing icons
            HStack(spacing: 8) {
                if isSaved {
                    // Checkmark + disconnect
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Color(hex: "b4e50d"))
                        .font(.system(size: 14))

                    Button(action: onDisconnect) {
                        Image(systemName: "xmark.circle")
                            .foregroundColor(.white.opacity(0.4))
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.borderless)
                } else {
                    // Eye toggle
                    Button(action: onToggleReveal) {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                            .foregroundColor(.white.opacity(0.4))
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.trailing, 10)
        }
        .frame(height: 35)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.10))
        )
    }
}

// MARK: - Shared CTA Button

private struct ConnectButton: View {
    let label: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundColor(isEnabled ? .white : .white.opacity(0.3))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(isEnabled ? 0.15 : 0.06))
                )
        }
        .buttonStyle(.borderless)
        .disabled(!isEnabled)
        .animation(.easeInOut(duration: 0.15), value: isEnabled)
    }
}

// MARK: - LLMProvider login URL extension

private extension LLMProvider {
    var loginURL: URL {
        switch self {
        case .claude:
            return URL(string: "https://claude.ai/login")!
        case .chatGPT:
            return URL(string: "https://chat.openai.com/auth/login")!
        case .cursor:
            return URL(string: "https://cursor.sh/settings")!
        case .antigravity:
            return URL(string: "https://aistudio.google.com")!
        case .openAIAPI:
            return URL(string: "https://platform.openai.com/api-keys")!
        }
    }
}
