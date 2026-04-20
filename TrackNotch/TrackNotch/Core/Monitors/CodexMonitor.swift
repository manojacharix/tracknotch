import Foundation
import SQLite3

/// Monitors ~/.codex/state_5.sqlite for Codex app usage.
/// Reads the `threads` table — no auth required.
@MainActor
final class CodexMonitor: ObservableObject {
    static let shared = CodexMonitor()

    @Published private(set) var isInstalled = false
    @Published private(set) var todayThreads: Int = 0
    @Published private(set) var todayTokens: Int = 0
    @Published private(set) var totalThreads: Int = 0
    @Published private(set) var modelBreakdown: [ModelUsage] = []
    @Published private(set) var isActivelyConsuming = false

    private var activityTimer: Timer?
    private let activityTimeout: TimeInterval = 30

    private let codexDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }()

    private var dbPath: String { codexDir.appendingPathComponent("state_5.sqlite").path }

    private var dbWatcher: DispatchSourceFileSystemObject?
    private var dbDescriptor: Int32 = -1
    private var scanTimer: Timer?

    private init() {}

    // MARK: - Lifecycle

    func start() {
        checkInstalled()
        guard isInstalled else { return }
        readDB()
        watchDB()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readDB() }
        }
    }

    func stop() {
        dbWatcher?.cancel()
        dbWatcher = nil
        scanTimer?.invalidate()
        scanTimer = nil
        activityTimer?.invalidate()
        activityTimer = nil
        if dbDescriptor >= 0 { Darwin.close(dbDescriptor); dbDescriptor = -1 }
    }

    // MARK: - Detection

    private func checkInstalled() {
        let fm = FileManager.default
        let appInstalled = fm.fileExists(atPath: "/Applications/Codex.app")
                        || fm.fileExists(atPath: "\(NSHomeDirectory())/Applications/Codex.app")
        isInstalled = appInstalled && fm.fileExists(atPath: dbPath)
    }

    // MARK: - File Watching

    private func watchDB() {
        dbDescriptor = Darwin.open(dbPath, O_EVTONLY)
        guard dbDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dbDescriptor,
            eventMask: [.write, .extend],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.readDB() }
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.dbDescriptor >= 0 { Darwin.close(self.dbDescriptor); self.dbDescriptor = -1 }
        }
        source.resume()
        dbWatcher = source
    }

    // MARK: - SQLite Reading

    private func readDB() {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else { return }
        defer { sqlite3_close(db) }

        let dayStart = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)

        let prevToday = todayThreads

        // Today's threads and tokens
        todayThreads = queryInt(db,
            "SELECT COUNT(*) FROM threads WHERE created_at >= \(dayStart) AND archived = 0")
        todayTokens = queryInt(db,
            "SELECT COALESCE(SUM(tokens_used), 0) FROM threads WHERE created_at >= \(dayStart) AND archived = 0")
        totalThreads = queryInt(db, "SELECT COUNT(*) FROM threads WHERE archived = 0")

        // Model breakdown — today only
        var breakdown: [String: Int] = [:]
        var stmt: OpaquePointer?
        let sql = "SELECT COALESCE(model, 'unknown'), COALESCE(SUM(tokens_used), 0) FROM threads WHERE created_at >= \(dayStart) AND archived = 0 GROUP BY model"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let model = String(cString: sqlite3_column_text(stmt, 0))
                let tokens = Int(sqlite3_column_int(stmt, 1))
                breakdown[model] = tokens
            }
        }
        sqlite3_finalize(stmt)

        modelBreakdown = breakdown.map { ModelUsage(modelName: $0.key, tokensUsed: $0.value, costUSD: nil) }
            .sorted { $0.tokensUsed > $1.tokensUsed }

        if todayThreads > prevToday { markActivity() }
    }

    private func queryInt(_ db: OpaquePointer, _ sql: String) -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func markActivity() {
        isActivelyConsuming = true
        activityTimer?.invalidate()
        activityTimer = Timer.scheduledTimer(withTimeInterval: activityTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.isActivelyConsuming = false }
        }
    }

    // MARK: - Usage conversion

    func toProviderUsage() -> ProviderUsage {
        let plan = AppSettings.shared.chatGPTPlanTier
        let cap  = plan.dailyCodexTaskCap
        let pct  = cap > 0 ? min(Double(todayThreads) / Double(cap) * 100, 100) : 0

        let tomorrow = Calendar.current.startOfDay(
            for: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        )

        return ProviderUsage(
            provider: .codex,
            billingType: .subscription,
            window: .daily,
            percentage: pct,
            resetsAt: tomorrow,
            tokensUsed: todayTokens,
            tokensLimit: nil,
            costUsedUSD: nil,
            costLimitUSD: nil,
            modelBreakdown: modelBreakdown,
            fetchedAt: Date(),
            isActivelyConsuming: isActivelyConsuming
        )
    }
}
