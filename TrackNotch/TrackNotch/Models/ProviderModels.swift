//
//  ProviderModels.swift
//  TrackNotch
//
//  Unified data models for multi-provider LLM usage tracking.
//  V1 providers: Claude, ChatGPT+Codex, Cursor, Antigravity
//

import Foundation
import SwiftUI

// MARK: - Provider

// MARK: - Billing Type

/// Whether a provider is billed via subscription (quota %) or API tokens ($ spend)
enum BillingType {
    case subscription  // flat plan — show quota %, reset time
    case apiToken      // pay-per-token — show $ spend, rolling arrow
}

// MARK: - Provider

enum LLMProvider: String, CaseIterable, Identifiable, Codable {
    case claude      = "claude"
    case chatGPT     = "chatgpt"    // ChatGPT + Codex (same subscription)
    case openAIAPI   = "openai_api" // OpenAI API (separate from ChatGPT subscription)
    case cursor      = "cursor"
    case antigravity = "antigravity" // Google AI plan (Plus/Pro/Ultra)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude:       return "Claude"
        case .chatGPT:      return "ChatGPT"
        case .openAIAPI:    return "OpenAI API"
        case .cursor:       return "Cursor"
        case .antigravity:  return "Antigravity"
        }
    }

    var iconName: String {
        switch self {
        case .claude:       return "claude-color"
        case .chatGPT:      return "openai"
        case .openAIAPI:    return "openai"
        case .cursor:       return "cursor"
        case .antigravity:  return "antigravity"
        }
    }

    /// Default billing type — can be overridden if user connects via API key
    var defaultBillingType: BillingType {
        switch self {
        case .claude:       return .subscription
        case .chatGPT:      return .subscription
        case .openAIAPI:    return .apiToken
        case .cursor:       return .subscription
        case .antigravity:  return .subscription
        }
    }

    var supportTier: ProviderSupportTier {
        switch self {
        case .claude:       return .full
        case .chatGPT:      return .full
        case .openAIAPI:    return .full
        case .cursor:       return .full
        case .antigravity:  return .partial
        }
    }

    var accentColor: Color {
        switch self {
        case .claude:       return Color(hex: "ff9b2f")  // orange
        case .chatGPT:      return Color(hex: "74aa9c")  // teal/green
        case .openAIAPI:    return Color(hex: "74aa9c")  // teal/green
        case .cursor:       return Color(hex: "ffffff")  // white
        case .antigravity:  return Color(hex: "4285f4")  // Google blue
        }
    }

    var authMethod: ProviderAuthMethod {
        switch self {
        case .claude:       return .sessionCookie
        case .chatGPT:      return .sessionCookie
        case .openAIAPI:    return .apiKey
        case .cursor:       return .localFiles
        case .antigravity:  return .sessionCookie
        }
    }
}

enum ProviderSupportTier {
    case full       // Reliable, official API or stable local files
    case partial    // Best-effort, may break on provider changes
}

enum ProviderAuthMethod {
    case apiKey
    case sessionCookie
    case localFiles
    case oAuth
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
    let billingType: BillingType    // subscription or apiToken
    let window: UsageWindow
    let percentage: Double          // 0–100
    let resetsAt: Date?
    let tokensUsed: Int?
    let tokensLimit: Int?
    let costUsedUSD: Double?
    let costLimitUSD: Double?
    let modelBreakdown: [ModelUsage]
    let fetchedAt: Date
    let isActivelyConsuming: Bool   // true when tokens flowing right now

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
