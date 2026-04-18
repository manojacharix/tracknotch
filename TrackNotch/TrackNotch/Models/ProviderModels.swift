//
//  ProviderModels.swift
//  TrackNotch
//
//  Unified data models for multi-provider LLM usage tracking.
//  Tier 1: Local file monitors (zero auth) — Claude Code, Codex, Cursor, ChatGPT Desktop
//  Tier 2: API keys (user pastes) — OpenAI API, Anthropic API
//

import Foundation
import SwiftUI

// MARK: - Billing Type

/// Whether a provider is billed via subscription (quota %) or API tokens ($ spend)
enum BillingType {
    case subscription  // flat plan — show quota %, reset time
    case apiToken      // pay-per-token — show $ spend, rolling arrow
    case localUsage    // local file monitor — show token counts, no cost
}

// MARK: - Provider

enum LLMProvider: String, CaseIterable, Identifiable, Codable {
    // Tier 1: Local file monitors (zero auth)
    case claudeCode     = "claude_code"
    case codex          = "codex"
    case cursorIDE      = "cursor_ide"
    case chatGPTDesktop = "chatgpt_desktop"

    // Tier 2: API keys
    case openAIAPI      = "openai_api"
    case anthropicAPI   = "anthropic_api"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode:     return "Claude Code"
        case .codex:          return "Codex"
        case .cursorIDE:      return "Cursor"
        case .chatGPTDesktop: return "ChatGPT Desktop"
        case .openAIAPI:      return "OpenAI API"
        case .anthropicAPI:   return "Anthropic API"
        }
    }

    var iconName: String {
        switch self {
        case .claudeCode:     return "claude-color"
        case .codex:          return "codex"
        case .cursorIDE:      return "cursor"
        case .chatGPTDesktop: return "antigravity"
        case .openAIAPI:      return "openai"
        case .anthropicAPI:   return "claude-color"
        }
    }

    var defaultBillingType: BillingType {
        switch self {
        case .claudeCode:     return .localUsage
        case .codex:          return .localUsage
        case .cursorIDE:      return .localUsage
        case .chatGPTDesktop: return .localUsage
        case .openAIAPI:      return .apiToken
        case .anthropicAPI:   return .apiToken
        }
    }

    var supportTier: ProviderSupportTier {
        switch self {
        case .claudeCode:     return .full
        case .codex:          return .full
        case .cursorIDE:      return .full
        case .chatGPTDesktop: return .partial
        case .openAIAPI:      return .full
        case .anthropicAPI:   return .full
        }
    }

    var accentColor: Color {
        switch self {
        case .claudeCode:     return Color(hex: "ff9b2f")  // orange
        case .codex:          return Color(hex: "74aa9c")   // teal/green
        case .cursorIDE:      return Color(hex: "ffffff")   // white
        case .chatGPTDesktop: return Color(hex: "74aa9c")   // teal/green
        case .openAIAPI:      return Color(hex: "74aa9c")   // teal/green
        case .anthropicAPI:   return Color(hex: "ff9b2f")   // orange
        }
    }

    /// Wing placement per Figma design:
    /// LEFT  wing: Cursor, OpenAI API, Codex
    /// RIGHT wing: Claude Code, Anthropic API, Antigravity, Google API
    var notchWing: NotchWing {
        switch self {
        case .cursorIDE:      return .left
        case .openAIAPI:      return .left
        case .codex:          return .left
        case .claudeCode:     return .right
        case .anthropicAPI:   return .right
        case .chatGPTDesktop: return .right   // antigravity-style, right
        }
    }

    // Keep authMethod for connection logic
    var authMethod: ProviderAuthMethod {
        switch self {
        case .claudeCode:     return .localFiles
        case .codex:          return .localFiles
        case .cursorIDE:      return .localFiles
        case .chatGPTDesktop: return .localFiles
        case .openAIAPI:      return .apiKey
        case .anthropicAPI:   return .apiKey
        }
    }

    /// Whether this provider is auto-detected from local files (no user action needed)
    var isAutoDetected: Bool {
        authMethod == .localFiles
    }

    /// Providers that require the user to paste an API key
    static var apiKeyProviders: [LLMProvider] {
        allCases.filter { $0.authMethod == .apiKey }
    }

    /// Providers that are auto-detected from local files
    static var localProviders: [LLMProvider] {
        allCases.filter { $0.authMethod == .localFiles }
    }
}

enum ProviderSupportTier {
    case full       // Reliable, official API or stable local files
    case partial    // Best-effort, may break on provider changes
}

enum ProviderAuthMethod {
    case apiKey
    case localFiles
}

enum NotchWing {
    case left
    case right
}

// MARK: - Usage Window

enum UsageWindow: String, Codable {
    case fiveHour  = "5h"
    case daily     = "24h"
    case weekly    = "7d"
    case monthly   = "30d"

    var displayName: String {
        switch self {
        case .fiveHour: return "5-hour"
        case .daily:    return "Daily"
        case .weekly:   return "Weekly"
        case .monthly:  return "Monthly"
        }
    }
}

// MARK: - Provider Usage

struct ProviderUsage: Equatable {
    let provider: LLMProvider
    let billingType: BillingType
    let window: UsageWindow
    let percentage: Double          // 0–100
    let resetsAt: Date?
    let tokensUsed: Int?
    let tokensLimit: Int?
    let costUsedUSD: Double?
    let costLimitUSD: Double?
    let modelBreakdown: [ModelUsage]
    let fetchedAt: Date
    let isActivelyConsuming: Bool

    var remaining: Double { max(0, 100 - percentage) }

    var usageLevel: UsageLevel {
        switch percentage {
        case 0..<20:  return .low
        case 20..<75: return .medium
        default:      return .high
        }
    }

    var resetsIn: TimeInterval? {
        guard let r = resetsAt else { return nil }
        return r.timeIntervalSinceNow
    }

    var formattedResetsIn: String {
        guard let seconds = resetsIn, seconds > 0 else { return "—" }
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours >= 24 { return "\(hours / 24)d \(hours % 24)h" }
        if hours > 0   { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    var formattedCost: String? {
        guard let cost = costUsedUSD else { return nil }
        return String(format: "$%.1f", cost)
    }

    var formattedTokens: String? {
        guard let tokens = tokensUsed else { return nil }
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return String(format: "%.1fK", Double(tokens) / 1_000) }
        return "\(tokens)"
    }

    static func empty(provider: LLMProvider) -> ProviderUsage {
        ProviderUsage(
            provider: provider,
            billingType: provider.defaultBillingType,
            window: .monthly,
            percentage: 0, resetsAt: nil,
            tokensUsed: nil, tokensLimit: nil,
            costUsedUSD: nil, costLimitUSD: nil,
            modelBreakdown: [], fetchedAt: Date(),
            isActivelyConsuming: false
        )
    }
}

struct ModelUsage: Equatable {
    let modelName: String
    let tokensUsed: Int
    let costUSD: Double?
}

// MARK: - Usage Level

enum UsageLevel {
    case low      // 0–20%:  lime green  #b4e50d
    case medium   // 20–75%: orange      #ff9b2f
    case high     // 75%+:   red         #fb4141
}

// MARK: - Budget Config

struct BudgetConfig: Codable, Equatable {
    let provider: LLMProvider
    let limitUSD: Double
    let alertAt: Double   // 0–1 fraction

    static func defaultConfig(for provider: LLMProvider) -> BudgetConfig {
        BudgetConfig(provider: provider, limitUSD: 20.0, alertAt: 0.8)
    }
}

// MARK: - Connection State

enum ProviderConnectionState: Equatable {
    case notConfigured
    case connecting
    case connected
    case error(String)
    case sessionExpired

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var displayText: String {
        switch self {
        case .notConfigured:   return "Not connected"
        case .connecting:      return "Connecting…"
        case .connected:       return "Connected"
        case .error(let msg):  return msg
        case .sessionExpired:  return "Session expired"
        }
    }
}

// MARK: - Color hex helper

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
