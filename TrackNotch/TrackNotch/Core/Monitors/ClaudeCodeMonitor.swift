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

    /// Context window fill of the most recently active session.
    /// Claude's usage fields are cumulative per session — the last assistant
    /// message always reflects the running total. input + output + cacheRead
    /// matches what Claude's own UI shows as "X% context used".
    @Published private(set) var activeSessionContextTokens: Int = 0
    /// Configurable context limit — default 200K (Claude Sonnet), user can adjust.
    static let defaultContextLimit = 200_000
    @Published private(set) var liveMessagesToday: Int = 0
    @Published private(set) var liveTokensToday: Int = 0

    /// Consider Claude active if any session file was modified within this window
    private let activityWindow: TimeInterval = 4

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
        guard isInstalled else {
            TNLog.info("[ClaudeCode] Not installed — skipping start", category: .monitor)
            return
        }
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
        let fm = FileManager.default
        guard fm.fileExists(atPath: claudeDir.path) else { isInstalled = false; return }
        // Accept if the binary exists in any common location, OR if stats-cache.json exists
        // (covers nvm/volta/custom PATH installs where the binary path varies)
        let home = NSHomeDirectory()
        let binaryInstalled = fm.fileExists(atPath: "/usr/local/bin/claude")
                           || fm.fileExists(atPath: "/opt/homebrew/bin/claude")
                           || fm.fileExists(atPath: "\(home)/.local/bin/claude")
                           || Self.claudeExistsInNvm(home: home)  // installed via npm in nvm
        let hasStatsFile = fm.fileExists(atPath: statsFile.path)
        isInstalled = binaryInstalled || hasStatsFile
    }

    /// Check if `claude` binary exists in any nvm node version's bin directory.
    private static func claudeExistsInNvm(home: String) -> Bool {
        let nvmVersions = "\(home)/.nvm/versions/node"
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: nvmVersions) else { return false }
        return dirs.contains { fm.fileExists(atPath: "\(nvmVersions)/\($0)/bin/claude") }
    }

    // MARK: - Activity polling

    /// Polls every 3 seconds. Activity detection uses only file modification dates (cheap).
    /// Heavy JSONL scanning runs on a background thread every 3rd poll (~9s).
    private var pollCount: Int = 0

    private func startActivityPolling() {
        pollTimer?.invalidate()
        pollCount = 0
        pollActivity()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollActivity() }
        }
    }

    private func pollActivity() {
        // Lightweight: only check file modification dates (no file reads)
        let latestDate = mostRecentModDate()
        let active: Bool
        if let modified = latestDate {
            active = Date().timeIntervalSince(modified) < activityWindow
        } else {
            active = false
        }
        if active != isActivelyConsuming { isActivelyConsuming = active }

        // Heavy scan (JSONL reads + context) — every 3rd poll (~9s) or when active
        pollCount += 1
        if active || pollCount % 3 == 0 {
            Task.detached(priority: .utility) { [claudeDir, historyFile] in
                let result = Self.scanAllJSONL(claudeDir: claudeDir, historyFile: historyFile)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if self.liveMessagesToday != result.messages { self.liveMessagesToday = result.messages }
                    if self.liveTokensToday != result.tokens { self.liveTokensToday = result.tokens }
                    if self.activeSessionContextTokens != result.contextTokens { self.activeSessionContextTokens = result.contextTokens }
                }
            }
        }
    }

    /// Lightweight: only checks file modification dates, no content reads.
    private func mostRecentModDate() -> Date? {
        let fm = FileManager.default
        var latest: Date? = nil

        func update(_ date: Date?) {
            guard let d = date else { return }
            if latest == nil || d > latest! { latest = d }
        }

        update((try? fm.attributesOfItem(atPath: historyFile.path))?[.modificationDate] as? Date)

        let projectsDir = claudeDir.appendingPathComponent("projects")
        guard let projectDirs = try? fm.contentsOfDirectory(at: projectsDir,
                                                             includingPropertiesForKeys: nil,
                                                             options: .skipsHiddenFiles) else { return latest }
        for projectDir in projectDirs {
            guard let sessions = try? fm.contentsOfDirectory(at: projectDir,
                                                              includingPropertiesForKeys: [.contentModificationDateKey],
                                                              options: .skipsHiddenFiles) else { continue }
            for file in sessions where file.pathExtension == "jsonl" {
                update((try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
            }
        }
        return latest
    }

    // MARK: - Background JSONL scan (consolidated single pass)

    private struct ScanResult {
        var messages: Int = 0
        var tokens: Int = 0
        var contextTokens: Int = 0
    }

    /// Runs entirely off the main thread. Single pass over all project dirs:
    /// counts today's messages, today's tokens, and reads active session context.
    private nonisolated static func scanAllJSONL(claudeDir: URL, historyFile: URL) -> ScanResult {
        let fm = FileManager.default
        let dayStart = Calendar.current.startOfDay(for: Date())
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var result = ScanResult()
        var latestSessionFile: URL? = nil
        var latestSessionDate: Date = .distantPast

        let projectsDir = claudeDir.appendingPathComponent("projects")
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return result }

        for projectDir in projectDirs {
            guard let files = try? fm.contentsOfDirectory(
                at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                let modDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast

                // Track most recent non-subagent session for context window
                if !file.path.contains("/subagents/") && modDate > latestSessionDate {
                    latestSessionDate = modDate
                    latestSessionFile = file
                }

                // Only scan files modified today for message/token counts
                guard modDate >= dayStart else { continue }
                guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }

                for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                    guard let data = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          obj["type"] as? String == "assistant",
                          let tsStr = obj["timestamp"] as? String,
                          let ts = iso.date(from: tsStr),
                          ts >= dayStart
                    else { continue }

                    result.messages += 1
                    if let msg = obj["message"] as? [String: Any],
                       let usage = msg["usage"] as? [String: Any] {
                        result.tokens += usage["output_tokens"] as? Int ?? 0
                    }
                }
            }
        }

        // Read active session context from the most recent file
        if let file = latestSessionFile,
           let content = try? String(contentsOf: file, encoding: .utf8) {
            let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
            for line in lines.reversed() {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      obj["type"] as? String == "assistant",
                      let msg = obj["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any]
                else { continue }

                let input      = usage["input_tokens"] as? Int ?? 0
                let cacheRead  = usage["cache_read_input_tokens"] as? Int ?? 0
                let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
                result.contextTokens = input + cacheRead + cacheWrite
                break
            }
        }

        return result
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
            // Debounce: stats-cache.json can be written in rapid bursts
            DispatchQueue.main.async {
                Task { @MainActor in self?.readStats() }
            }
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

    // MARK: - Token computations

    var weeklyTokens: Int {
        let cal = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        // Past 6 days from stats-cache + today's live JSONL count (more up-to-date)
        let pastDates = Set((1..<7).compactMap { daysAgo in
            cal.date(byAdding: .day, value: -daysAgo, to: Date()).map { formatter.string(from: $0) }
        })
        let pastTokens = dailyModelTokens
            .filter { pastDates.contains($0.date) }
            .reduce(0) { $0 + $1.tokens }
        return pastTokens + todayTokens
    }

    /// Messages sent today — prefers live JSONL count over stats-cache.
    var todayMessages: Int {
        if liveMessagesToday > 0 { return liveMessagesToday }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let todayStr = formatter.string(from: Date())
        return dailyActivity.first { $0.date == todayStr }?.messageCount ?? 0
    }

    /// Tokens used today — prefers live JSONL count over stats-cache.
    var todayTokens: Int {
        if liveTokensToday > 0 { return liveTokensToday }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let todayStr = formatter.string(from: Date())
        return dailyModelTokens.first { $0.date == todayStr }?.tokens ?? 0
    }

    // MARK: - Usage conversion

    func toProviderUsage() -> ProviderUsage {
        // Arc = weekly output tokens used vs plan's weekly cap.
        // This reflects actual quota depletion — when the arc is full, you're rate-limited.
        let plan = AppSettings.shared.claudePlanTier
        let weeklyCap = plan.weeklyTokenCap
        let weeklyUsed = weeklyTokens
        let pct = weeklyCap > 0 ? min(Double(weeklyUsed) / Double(weeklyCap) * 100, 100) : 0

        return ProviderUsage(
            provider: .claudeCode,
            billingType: .subscription,
            window: .weekly,
            percentage: pct,
            resetsAt: nil,
            tokensUsed: weeklyUsed,
            tokensLimit: weeklyCap,
            costUsedUSD: nil,
            costLimitUSD: nil,
            modelBreakdown: modelBreakdown,
            fetchedAt: Date(),
            isActivelyConsuming: isActivelyConsuming
        )
    }
}
