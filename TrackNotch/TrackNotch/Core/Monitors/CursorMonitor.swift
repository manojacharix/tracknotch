import Foundation
import SQLite3

/// Monitors ~/.cursor/ai-tracking/ai-code-tracking.db for Cursor IDE usage.
/// Zero auth — reads the local SQLite database written by Cursor.
@MainActor
final class CursorMonitor: ObservableObject {
    static let shared = CursorMonitor()

    @Published private(set) var isInstalled = false
    @Published private(set) var totalGenerations: Int = 0
    @Published private(set) var totalConversations: Int = 0
    @Published private(set) var modelBreakdown: [ModelUsage] = []
    @Published private(set) var isActivelyConsuming = false

    private var activityTimer: Timer?
    private let activityTimeout: TimeInterval = 30

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
        isInstalled = FileManager.default.fileExists(atPath: dbPath)
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

        let prevGenerations = totalGenerations

        // Count total AI code generations
        totalGenerations = queryInt(db, "SELECT COUNT(*) FROM ai_code_hashes")

        // Count conversations
        totalConversations = queryInt(db, "SELECT COUNT(*) FROM conversation_summaries")

        // Model breakdown from ai_code_hashes
        var breakdown: [String: Int] = [:]
        var stmt: OpaquePointer?
        let sql = "SELECT COALESCE(model, 'unknown'), COUNT(*) FROM ai_code_hashes GROUP BY model"
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

        if totalGenerations > prevGenerations { markActivity() }
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
        let cap = plan.monthlyFastRequestCap
        let pct = cap > 0 ? min(Double(totalGenerations) / Double(cap) * 100, 100) : 0

        return ProviderUsage(
            provider: .cursorIDE,
            billingType: .subscription,
            window: .monthly,
            percentage: pct,
            resetsAt: nil,
            tokensUsed: totalGenerations,
            tokensLimit: cap,
            costUsedUSD: nil,
            costLimitUSD: nil,
            modelBreakdown: modelBreakdown,
            fetchedAt: Date(),
            isActivelyConsuming: isActivelyConsuming
        )
    }
}
