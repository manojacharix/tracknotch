import Foundation
import Combine

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var idleCollapseTimeout: IdleTimeout = .thirtyMinutes
    @Published var launchAtLogin: Bool = false

    // Plan tiers for subscription providers
    @Published var claudePlanTier: ClaudePlanTier {
        didSet { UserDefaults.standard.set(claudePlanTier.rawValue, forKey: "claudePlanTier") }
    }
    @Published var chatGPTPlanTier: ChatGPTPlanTier {
        didSet { UserDefaults.standard.set(chatGPTPlanTier.rawValue, forKey: "chatGPTPlanTier") }
    }
    @Published var cursorPlanTier: CursorPlanTier {
        didSet { UserDefaults.standard.set(cursorPlanTier.rawValue, forKey: "cursorPlanTier") }
    }

    // Monthly budget caps for API providers (USD)
    @Published var openAIMonthlyBudget: Double {
        didSet { UserDefaults.standard.set(openAIMonthlyBudget, forKey: "openAIMonthlyBudget") }
    }
    @Published var anthropicMonthlyBudget: Double {
        didSet { UserDefaults.standard.set(anthropicMonthlyBudget, forKey: "anthropicMonthlyBudget") }
    }

    private init() {
        claudePlanTier = ClaudePlanTier(rawValue: UserDefaults.standard.string(forKey: "claudePlanTier") ?? "") ?? .pro
        chatGPTPlanTier = ChatGPTPlanTier(rawValue: UserDefaults.standard.string(forKey: "chatGPTPlanTier") ?? "") ?? .plus
        cursorPlanTier = CursorPlanTier(rawValue: UserDefaults.standard.string(forKey: "cursorPlanTier") ?? "") ?? .pro
        openAIMonthlyBudget = UserDefaults.standard.object(forKey: "openAIMonthlyBudget") as? Double ?? 20.0
        anthropicMonthlyBudget = UserDefaults.standard.object(forKey: "anthropicMonthlyBudget") as? Double ?? 20.0
    }
}

// MARK: - Plan Tiers

enum ClaudePlanTier: String, CaseIterable, Identifiable {
    case free = "Free"
    case pro = "Pro"
    case max5 = "Max (5x)"
    case max20 = "Max (20x)"
    case team = "Team"

    var id: String { rawValue }

    /// Weekly token cap for the plan (approximate, based on public info)
    var weeklyTokenCap: Int {
        switch self {
        case .free:  return 200_000
        case .pro:   return 2_500_000
        case .max5:  return 12_500_000
        case .max20: return 50_000_000
        case .team:  return 5_000_000
        }
    }

    /// 5-hour message cap
    var fiveHourMessageCap: Int {
        switch self {
        case .free:  return 10
        case .pro:   return 45
        case .max5:  return 225
        case .max20: return 900
        case .team:  return 100
        }
    }
}

enum ChatGPTPlanTier: String, CaseIterable, Identifiable {
    case free = "Free"
    case plus = "Plus"
    case pro = "Pro"

    var id: String { rawValue }

    /// Daily Codex task cap
    var dailyCodexTaskCap: Int {
        switch self {
        case .free:  return 5
        case .plus:  return 50
        case .pro:   return 200
        }
    }
}

enum CursorPlanTier: String, CaseIterable, Identifiable {
    case hobby = "Hobby"
    case pro = "Pro"
    case business = "Business"

    var id: String { rawValue }

    /// Monthly fast request cap
    var monthlyFastRequestCap: Int {
        switch self {
        case .hobby:    return 50
        case .pro:      return 500
        case .business: return 500
        }
    }
}

enum IdleTimeout: String, CaseIterable, Identifiable {
    case never = "Never"
    case fiveMinutes = "5 minutes"
    case fifteenMinutes = "15 minutes"
    case thirtyMinutes = "30 minutes"
    case oneHour = "1 hour"
    case onScreenLock = "When screen locks"

    var id: String { rawValue }

    var seconds: TimeInterval? {
        switch self {
        case .never: return nil
        case .fiveMinutes: return 300
        case .fifteenMinutes: return 900
        case .thirtyMinutes: return 1800
        case .oneHour: return 3600
        case .onScreenLock: return nil
        }
    }
}
