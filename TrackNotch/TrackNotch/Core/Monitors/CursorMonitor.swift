import Foundation
import SQLite3

/// Monitors ~/.cursor/ai-tracking/ai-code-tracking.db for Cursor IDE usage.
/// Zero auth — reads the local SQLite database written by Cursor.
@MainActor
final class CursorMonitor: ObservableObject {
    static let shared = CursorMonitor()

    @Published private(set) var isInstalled = false
    @Published private(set) var monthlyGenerations: Int = 0
    @Published private(set) var todayGenerations: Int = 0
    @Published private(set) var totalConversations: Int = 0
    @Published private(set) var modelBreakdown: [ModelUsage] = []
    @Published private(set) var isActivelyConsuming = false

    private var activityTimer: Timer?
    private let activityTimeout: TimeInterval = 30
    private var isFirstRead = true

    private let dbPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.cursor/ai-tracking/ai-code-tracking.db"
    }()

    private var fileWatcher: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1

    private init() {}

    // MARK: - Lifecycle

    func start() {
        checkInstalled()
        guard isInstalled else { return }
        readDB()
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
        let fm = FileManager.default
        let appInstalled = fm.fileExists(atPath: "/Applications/Cursor.app")
                        || fm.fileExists(atPath: "\(NSHomeDirectory())/Applications/Cursor.app")
        isInstalled = appInstalled && fm.fileExists(atPath: dbPath)
    }

    private func markActivity() {
        isActivelyConsuming = true
        activityTimer?.invalidate()
        activityTimer = Timer.scheduledTimer(withTimeInterval: activityTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.isActivelyConsuming = false }
        }
    }

    // MARK: - File Watching

    private func watchFile() {
        fileDescriptor = Darwin.open(dbPath, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend],
            queue: .global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.readDB()
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

    // MARK: - SQLite Reading

    private func readDB() {
        var db: OpaquePointer?
        // Open read-only to avoid locking Cursor's DB
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db = db else { return }
        defer { sqlite3_close(db) }

        let prevGenerations = monthlyGenerations

        // Count AI code generations for the current calendar month only.
        // createdAt is stored as Unix milliseconds.
        let monthStartMs = Self.currentMonthStartMs()
        let dayStartMs   = Self.currentDayStartMs()
        monthlyGenerations = queryInt(db,
            "SELECT COUNT(*) FROM ai_code_hashes WHERE createdAt >= \(monthStartMs)")
        todayGenerations = queryInt(db,
            "SELECT COUNT(*) FROM ai_code_hashes WHERE createdAt >= \(dayStartMs)")

        // Count conversations
        totalConversations = queryInt(db, "SELECT COUNT(*) FROM conversation_summaries")

        // Model breakdown from ai_code_hashes — current month only
        var breakdown: [String: Int] = [:]
        var stmt: OpaquePointer?
        let sql = "SELECT COALESCE(model, 'unknown'), COUNT(*) FROM ai_code_hashes WHERE createdAt >= \(monthStartMs) GROUP BY model"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let model = String(cString: sqlite3_column_text(stmt, 0))
                let count = Int(sqlite3_column_int(stmt, 1))
                breakdown[model] = count
            }
        }
        sqlite3_finalize(stmt)

        modelBreakdown = breakdown.map { ModelUsage(modelName: $0.key, tokensUsed: $0.value, costUSD: nil) }
            .sorted { $0.tokensUsed > $1.tokensUsed }

        // Skip the initial read so pre-existing DB records don't falsely trigger activity
        if !isFirstRead && monthlyGenerations > prevGenerations { markActivity() }
        isFirstRead = false
    }

    /// Returns the Unix timestamp in milliseconds for the start of the current calendar month.
    private static func currentMonthStartMs() -> Int64 {
        let cal = Calendar.current
        let now = Date()
        let components = cal.dateComponents([.year, .month], from: now)
        let monthStart = cal.date(from: components) ?? now
        return Int64(monthStart.timeIntervalSince1970 * 1000)
    }

    /// Returns the Unix timestamp in milliseconds for the start of today.
    private static func currentDayStartMs() -> Int64 {
        let dayStart = Calendar.current.startOfDay(for: Date())
        return Int64(dayStart.timeIntervalSince1970 * 1000)
    }

    private func queryInt(_ db: OpaquePointer, _ sql: String) -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    // MARK: - Usage conversion

    func toProviderUsage() -> ProviderUsage {
        let plan = AppSettings.shared.cursorPlanTier
        // Arc shows today's requests vs daily budget (monthly cap / 30).
        let dailyCap = max(1, plan.monthlyFastRequestCap / 30)
        let pct = min(Double(todayGenerations) / Double(dailyCap) * 100, 100)

        return ProviderUsage(
            provider: .cursorIDE,
            billingType: .subscription,
            window: .daily,
            percentage: pct,
            resetsAt: nil,
            tokensUsed: todayGenerations,
            tokensLimit: dailyCap,
            costUsedUSD: nil,
            costLimitUSD: nil,
            modelBreakdown: modelBreakdown,
            fetchedAt: Date(),
            isActivelyConsuming: isActivelyConsuming
        )
    }
}
