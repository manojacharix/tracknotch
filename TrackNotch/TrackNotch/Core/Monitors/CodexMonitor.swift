import Foundation

/// Monitors ~/.codex/sessions/ for OpenAI Codex CLI usage.
/// Zero auth — reads local JSONL session files.
@MainActor
final class CodexMonitor: ObservableObject {
    static let shared = CodexMonitor()

    @Published private(set) var isInstalled = false
    @Published private(set) var totalTokens: Int = 0
    @Published private(set) var totalSessions: Int = 0
    @Published private(set) var modelBreakdown: [ModelUsage] = []
    @Published private(set) var isActivelyConsuming = false

    private var activityTimer: Timer?
    private let activityTimeout: TimeInterval = 30

    private let codexDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }()

    private var sessionsDir: URL {
        codexDir.appendingPathComponent("sessions")
    }

    private var dirWatcher: DispatchSourceFileSystemObject?
    private var dirDescriptor: Int32 = -1
    private var scanTimer: Timer?

    private init() {}

    // MARK: - Lifecycle

    func start() {
        checkInstalled()
        guard isInstalled else { return }
        scanSessions()
        watchDirectory()
        // Periodic rescan every 60s in case directory watches miss nested changes
        scanTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scanSessions() }
        }
    }

    func stop() {
        dirWatcher?.cancel()
        dirWatcher = nil
        scanTimer?.invalidate()
        scanTimer = nil
        activityTimer?.invalidate()
        activityTimer = nil
        if dirDescriptor >= 0 {
            close(dirDescriptor)
            dirDescriptor = -1
        }
    }

    // MARK: - Detection

    private func checkInstalled() {
        isInstalled = FileManager.default.fileExists(atPath: codexDir.path)
    }

    // MARK: - Directory Watching

    private func watchDirectory() {
        let path = sessionsDir.path
        guard FileManager.default.fileExists(atPath: path) else { return }

        dirDescriptor = Darwin.open(path, O_EVTONLY)
        guard dirDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirDescriptor,
            eventMask: [.write, .extend],
            queue: .global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.scanSessions()
            }
        }

        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.dirDescriptor >= 0 {
                Darwin.close(self.dirDescriptor)
                self.dirDescriptor = -1
            }
        }

        source.resume()
        dirWatcher = source
    }

    // MARK: - Session Scanning

    private func markActivity() {
        isActivelyConsuming = true
        activityTimer?.invalidate()
        activityTimer = Timer.scheduledTimer(withTimeInterval: activityTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.isActivelyConsuming = false }
        }
    }

    private func scanSessions() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sessionsDir.path) else { return }

        let prevTokens = totalTokens

        // Find all JSONL files recursively under sessions/
        guard let enumerator = fm.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var sessionCount = 0
        var tokens = 0
        var models: [String: Int] = [:]

        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }
            sessionCount += 1
            parseJSONLFile(url, tokens: &tokens, models: &models)
        }

        totalSessions = sessionCount
        totalTokens = tokens
        modelBreakdown = models.map { ModelUsage(modelName: $0.key, tokensUsed: $0.value, costUSD: nil) }
            .sorted { $0.tokensUsed > $1.tokensUsed }

        if tokens > prevTokens { markActivity() }
    }

    private func parseJSONLFile(_ url: URL, tokens: inout Int, models: inout [String: Int]) {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return }

        for line in data.split(separator: "\n") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }

            // Extract token counts from event_msg with token_count type
            if let type = json["type"] as? String, type == "event_msg",
               let payload = json["payload"] as? [String: Any],
               let payloadType = payload["type"] as? String, payloadType == "token_count",
               let info = payload["info"] as? [String: Any],
               let usage = info["total_token_usage"] as? [String: Any] {
                let total = usage["totalTokens"] as? Int ?? 0
                tokens += total
            }

            // Extract model from turn_context
            if let type = json["type"] as? String, type == "turn_context",
               let payload = json["payload"] as? [String: Any],
               let model = payload["model"] as? String {
                models[model, default: 0] += 1
            }
        }
    }

    // MARK: - Daily session count

    /// Count sessions started today (by checking file modification dates)
    var todaySessions: Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sessionsDir.path),
              let enumerator = fm.enumerator(
                  at: sessionsDir,
                  includingPropertiesForKeys: [.contentModificationDateKey],
                  options: [.skipsHiddenFiles]
              ) else { return totalSessions }

        let cal = Calendar.current
        var count = 0
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }
            if let modDate = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               cal.isDateInToday(modDate) {
                count += 1
            }
        }
        return count
    }

    // MARK: - Usage conversion

    func toProviderUsage() -> ProviderUsage {
        let plan = AppSettings.shared.chatGPTPlanTier
        let cap = plan.dailyCodexTaskCap
        let daily = todaySessions
        let pct = cap > 0 ? min(Double(daily) / Double(cap) * 100, 100) : 0

        // Reset time: next midnight
        let cal = Calendar.current
        let tomorrow = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: Date()) ?? Date())

        return ProviderUsage(
            provider: .codex,
            billingType: .subscription,
            window: .daily,
            percentage: pct,
            resetsAt: tomorrow,
            tokensUsed: daily,
            tokensLimit: cap,
            costUsedUSD: nil,
            costLimitUSD: nil,
            modelBreakdown: modelBreakdown,
            fetchedAt: Date(),
            isActivelyConsuming: isActivelyConsuming
        )
    }
}
