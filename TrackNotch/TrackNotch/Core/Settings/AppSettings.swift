import Foundation
import Combine
import ServiceManagement

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var launchAtLogin: Bool = false {
        didSet {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                TNLog.error("[Settings] Launch at login failed: \(error.localizedDescription)", category: .ui)
                // Revert on failure without triggering didSet again
                if launchAtLogin != oldValue {
                    launchAtLogin = oldValue
                }
            }
        }
    }

    /// Context window size for the arc. Default 200K = Sonnet. Set to 1M for Opus.
    @Published var claudeContextLimit: Int {
        didSet { UserDefaults.standard.set(claudeContextLimit, forKey: "claudeContextLimit") }
    }

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
        claudeContextLimit = UserDefaults.standard.object(forKey: "claudeContextLimit") as? Int ?? 200_000
        claudePlanTier = ClaudePlanTier(rawValue: UserDefaults.standard.string(forKey: "claudePlanTier") ?? "") ?? .pro
        chatGPTPlanTier = ChatGPTPlanTier(rawValue: UserDefaults.standard.string(forKey: "chatGPTPlanTier") ?? "") ?? .plus
        cursorPlanTier = CursorPlanTier(rawValue: UserDefaults.standard.string(forKey: "cursorPlanTier") ?? "") ?? .pro
        openAIMonthlyBudget = UserDefaults.standard.object(forKey: "openAIMonthlyBudget") as? Double ?? 20.0
        anthropicMonthlyBudget = UserDefaults.standard.object(forKey: "anthropicMonthlyBudget") as? Double ?? 20.0

        // Sync launch-at-login with system state
        launchAtLogin = SMAppService.mainApp.status == .enabled
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

    /// Daily output-token reference for the arc.
    /// Based on observed typical output budgets per plan — output tokens are
    /// the real measure of work done (cache reads inflate totals without new generation).
    var dailyOutputTokenCap: Int {
        switch self {
        case .free:  return 20_000
        case .pro:   return 100_000
        case .max5:  return 500_000
        case .max20: return 2_000_000
        case .team:  return 200_000
        }
    }

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

