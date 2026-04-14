import Foundation
import Combine

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var idleCollapseTimeout: IdleTimeout = .thirtyMinutes
    @Published var launchAtLogin: Bool = false

    private init() {}
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
