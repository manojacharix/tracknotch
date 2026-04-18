import Foundation

/// Monitors ~/.claude/ for Claude Code usage.
/// - Activity: polls history.jsonl modification date every 3s (file watcher unreliable for appends)
/// - Token counts: reads stats-cache.json via file watcher + initial read
@MainActor
final class ClaudeCodeMonitor: ObservableObject {
    static let shared = ClaudeCodeMonitor()

    @Published private(set) var isInstalled = false
    @Published private(set) var totalTokens: Int = 0
    @Published private(set) var totalSessions: Int = 0
    @Published private(set) var totalMessages: Int = 0
    @Published private(set) var modelBreakdown: [ModelUsage] = []
    @Published private(set) var dailyActivity: [DailyActivity] = []
    @Published private(set) var dailyModelTokens: [DailyTokens] = []
    @Published private(set) var isActivelyConsuming = false

    /// Consider Claude active if any session file was modified within this window
    private let activityWindow: TimeInterval = 2

    struct DailyActivity {
        let date: String
        let messageCount: Int
        let sessionCount: Int
        let toolCallCount: Int
    }

    struct DailyTokens {
        let date: String
        let tokens: Int
    }

    private let claudeDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }()

    private var statsFile: URL { claudeDir.appendingPathComponent("stats-cache.json") }
    private var historyFile: URL { claudeDir.appendingPathComponent("history.jsonl") }

    private var statsWatcher: DispatchSourceFileSystemObject?
    private var statsDescriptor: Int32 = -1
    private var pollTimer: Timer?

    private init() {}

    // MARK: - Lifecycle

    func start() {
        checkInstalled()
        guard isInstalled else { return }
        readStats()
        watchStatsFile()
        startActivityPolling()
    }

    func stop() {
        statsWatcher?.cancel()
        statsWatcher = nil
        pollTimer?.invalidate()
        pollTimer = nil
        if statsDescriptor >= 0 { close(statsDescriptor); statsDescriptor = -1 }
    }

    // MARK: - Installation check

    private func checkInstalled() {
        isInstalled = FileManager.default.fileExists(atPath: claudeDir.path)
    }

    // MARK: - Activity polling

    /// Polls session file modification dates every 1 second for responsive activity detection.
    private func startActivityPolling() {
        pollTimer?.invalidate()
        // Fire immediately, then repeat
        pollActivity()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollActivity() }
        }
    }

    private func pollActivity() {
        let latestDate = mostRecentClaudeActivity()
        guard let modified = latestDate else {
            if isActivelyConsuming { isActivelyConsuming = false }
            return
        }
        let active = Date().timeIntervalSince(modified) < activityWindow
        if active != isActivelyConsuming {
            isActivelyConsuming = active
        }
    }

    /// Returns the modification date of the most recently touched Claude Code file.
    /// Checks history.jsonl AND all session JSONL files inside ~/.claude/projects/
    /// because the Xcode extension updates session files but not history.jsonl.
    private func mostRecentClaudeActivity() -> Date? {
        let fm = FileManager.default
        var latestDate: Date? = nil

        func update(_ date: Date?) {
            guard let d = date else { return }
            if latestDate == nil || d > latestDate! { latestDate = d }
        }

        // history.jsonl (CLI usage)
        update((try? fm.attributesOfItem(atPath: historyFile.path))?[.modificationDate] as? Date)

        // Session JSONL files inside ~/.claude/projects/<project-dir>/*.jsonl
        let projectsDir = claudeDir.appendingPathComponent("projects")
        if let projectDirs = try? fm.contentsOfDirectory(at: projectsDir,
                                                          includingPropertiesForKeys: nil,
                                                          options: .skipsHiddenFiles) {
            for projectDir in projectDirs {
                if let sessions = try? fm.contentsOfDirectory(at: projectDir,
                                                               includingPropertiesForKeys: [.contentModificationDateKey],
                                                               options: .skipsHiddenFiles) {
                    for file in sessions where file.pathExtension == "jsonl" {
                        update((try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
                    }
                }
            }
        }

        return latestDate
    }

    // MARK: - Stats file watching

    private func watchStatsFile() {
        let path = statsFile.path
        statsDescriptor = Darwin.open(path, O_EVTONLY)
        guard statsDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: statsDescriptor,
            eventMask: [.write, .extend, .rename],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.readStats() }
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.statsDescriptor >= 0 { Darwin.close(self.statsDescriptor); self.statsDescriptor = -1 }
        }
        source.resume()
        statsWatcher = source
    }

    // MARK: - Stats parsing

    private func readStats() {
        guard let data = try? Data(contentsOf: statsFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        totalSessions = json["totalSessions"] as? Int ?? 0
        totalMessages = json["totalMessages"] as? Int ?? 0

        if let modelUsage = json["modelUsage"] as? [String: [String: Any]] {
            var breakdown: [ModelUsage] = []
            var total = 0
            for (model, usage) in modelUsage {
                let input        = usage["inputTokens"] as? Int ?? 0
                let output       = usage["outputTokens"] as? Int ?? 0
                let cacheRead    = usage["cacheReadInputTokens"] as? Int ?? 0
                let cacheCreate  = usage["cacheCreationInputTokens"] as? Int ?? 0
                let modelTotal   = input + output + cacheRead + cacheCreate
                total += modelTotal
                let cost = usage["costUSD"] as? Double
                breakdown.append(ModelUsage(modelName: model, tokensUsed: modelTotal, costUSD: cost))
            }
            totalTokens = total
            modelBreakdown = breakdown.sorted { $0.tokensUsed > $1.tokensUsed }
        }

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

        if let dailyTokenEntries = json["dailyModelTokens"] as? [[String: Any]] {
            dailyModelTokens = dailyTokenEntries.compactMap { entry in
                guard let date = entry["date"] as? String,
                      let byModel = entry["tokensByModel"] as? [String: Int] else { return nil }
                return DailyTokens(date: date, tokens: byModel.values.reduce(0, +))
            }
        }
    }

    // MARK: - Weekly token computation

    var weeklyTokens: Int {
        let cal = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let recentDates = Set((0..<7).compactMap { daysAgo in
            cal.date(byAdding: .day, value: -daysAgo, to: Date()).map { formatter.string(from: $0) }
        })
        return dailyModelTokens
            .filter { recentDates.contains($0.date) }
            .reduce(0) { $0 + $1.tokens }
    }

    // MARK: - Usage conversion

    func toProviderUsage() -> ProviderUsage {
        let plan   = AppSettings.shared.claudePlanTier
        let cap    = plan.weeklyTokenCap
        let weekly = weeklyTokens
        let pct    = cap > 0 ? min(Double(weekly) / Double(cap) * 100, 100) : 0

        return ProviderUsage(
            provider: .claudeCode,
            billingType: .subscription,
            window: .weekly,
            percentage: pct,
            resetsAt: nil,
            tokensUsed: weekly,
            tokensLimit: cap,
            costUsedUSD: nil,
            costLimitUSD: nil,
            modelBreakdown: modelBreakdown,
            fetchedAt: Date(),
            isActivelyConsuming: isActivelyConsuming
        )
    }
}
