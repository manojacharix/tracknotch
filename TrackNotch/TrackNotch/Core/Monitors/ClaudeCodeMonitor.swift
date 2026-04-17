import Foundation

/// Monitors ~/.claude/stats-cache.json for Claude Code usage data.
/// Zero auth — reads local files written by Claude Code CLI.
@MainActor
final class ClaudeCodeMonitor: ObservableObject {
    static let shared = ClaudeCodeMonitor()

    @Published private(set) var isInstalled = false
    @Published private(set) var totalTokens: Int = 0
    @Published private(set) var totalSessions: Int = 0
    @Published private(set) var totalMessages: Int = 0
    @Published private(set) var modelBreakdown: [ModelUsage] = []
    @Published private(set) var dailyActivity: [DailyActivity] = []
    @Published private(set) var isActivelyConsuming = false

    /// Tracks the last time the stats file changed to infer active consumption
    private var lastActivityDate: Date?
    private var activityTimer: Timer?
    private let activityTimeout: TimeInterval = 30  // idle after 30s of no file changes

    struct DailyActivity {
        let date: String
        let messageCount: Int
        let sessionCount: Int
        let toolCallCount: Int
    }

    private let claudeDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }()

    private var statsFile: URL {
        claudeDir.appendingPathComponent("stats-cache.json")
    }

    private var fileWatcher: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1

    private init() {}

    // MARK: - Lifecycle

    func start() {
        checkInstalled()
        guard isInstalled else { return }
        readStats()
        watchFile()
    }

    func stop() {
        fileWatcher?.cancel()
        fileWatcher = nil
        activityTimer?.invalidate()
        activityTimer = nil
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    // MARK: - Detection

    private func checkInstalled() {
        isInstalled = FileManager.default.fileExists(atPath: claudeDir.path)
    }

    // MARK: - File Watching

    private func watchFile() {
        let path = statsFile.path
        fileDescriptor = Darwin.open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .rename],
            queue: .global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.readStats()
            }
        }

        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileDescriptor >= 0 {
                Darwin.close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }

        source.resume()
        fileWatcher = source
    }

    // MARK: - Parsing

    private func readStats() {
        guard let data = try? Data(contentsOf: statsFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        markActivity()

        totalSessions = json["totalSessions"] as? Int ?? 0
        totalMessages = json["totalMessages"] as? Int ?? 0

        // Parse model usage
        if let modelUsage = json["modelUsage"] as? [String: [String: Any]] {
            var breakdown: [ModelUsage] = []
            var total = 0
            for (model, usage) in modelUsage {
                let input = usage["inputTokens"] as? Int ?? 0
                let output = usage["outputTokens"] as? Int ?? 0
                let cacheRead = usage["cacheReadInputTokens"] as? Int ?? 0
                let cacheCreate = usage["cacheCreationInputTokens"] as? Int ?? 0
                let modelTotal = input + output + cacheRead + cacheCreate
                total += modelTotal
                let cost = usage["costUSD"] as? Double
                breakdown.append(ModelUsage(modelName: model, tokensUsed: modelTotal, costUSD: cost))
            }
            totalTokens = total
            modelBreakdown = breakdown.sorted { $0.tokensUsed > $1.tokensUsed }
        }

        // Parse daily activity
        if let daily = json["dailyActivity"] as? [[String: Any]] {
            dailyActivity = daily.compactMap { entry in
                guard let date = entry["date"] as? String else { return nil }
                return DailyActivity(
                    date: date,
                    messageCount: entry["messageCount"] as? Int ?? 0,
                    sessionCount: entry["sessionCount"] as? Int ?? 0,
                    toolCallCount: entry["toolCallCount"] as? Int ?? 0
                )
            }
        }
    }

    // MARK: - Activity Detection

    private func markActivity() {
        lastActivityDate = Date()
        isActivelyConsuming = true
        activityTimer?.invalidate()
        activityTimer = Timer.scheduledTimer(withTimeInterval: activityTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.isActivelyConsuming = false
            }
        }
    }

    // MARK: - Weekly token computation

    /// Tokens consumed in the last 7 days, derived from daily activity
    var weeklyTokens: Int {
        let cal = Calendar.current
        let sevenDaysAgo = cal.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let cutoff = formatter.string(from: sevenDaysAgo)

        // Sum tokens from daily activity entries within the last 7 days
        // Daily activity tracks messages/sessions — approximate tokens from total
        // If we have per-day token data, use it; otherwise fall back to total
        return totalTokens  // TODO: refine when per-day token breakdowns are available
    }

    // MARK: - Usage conversion

    func toProviderUsage() -> ProviderUsage {
        let plan = AppSettings.shared.claudePlanTier
        let cap = plan.weeklyTokenCap
        let pct = cap > 0 ? min(Double(totalTokens) / Double(cap) * 100, 100) : 0

        return ProviderUsage(
            provider: .claudeCode,
            billingType: .subscription,
            window: .weekly,
            percentage: pct,
            resetsAt: nil,
            tokensUsed: totalTokens,
            tokensLimit: cap,
            costUsedUSD: nil,
            costLimitUSD: nil,
            modelBreakdown: modelBreakdown,
            fetchedAt: Date(),
            isActivelyConsuming: isActivelyConsuming
        )
    }
}
