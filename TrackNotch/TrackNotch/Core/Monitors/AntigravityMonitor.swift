import AppKit
import Foundation

/// Monitors Google Antigravity (a VS Code-based fork that uses Gemini CloudCode)
/// by scanning ~/.gemini/antigravity/. Each "brain/<UUID>" directory is one
/// AI-driven task session. Zero auth — purely local files.
@MainActor
final class AntigravityMonitor: ObservableObject {
    static let shared = AntigravityMonitor()

    @Published private(set) var isInstalled = false
    @Published private(set) var totalSessions: Int = 0
    @Published private(set) var monthlySessions: Int = 0
    @Published private(set) var todaySessions: Int = 0
    @Published private(set) var modelBreakdown: [ModelUsage] = []
    @Published private(set) var isActivelyConsuming = false

    private var activityTimer: Timer?
    private let activityTimeout: TimeInterval = 30

    /// ~/.gemini/antigravity is where Antigravity stores task sessions and code edits.
    /// The Electron app data dir at ~/Library/Application Support/Antigravity/ holds
    /// only Chromium browser state (Local Storage, caches) — no usage signal.
    private let geminiDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity")
    }()

    private var brainDir: URL { geminiDir.appendingPathComponent("brain") }
    private var codeTrackerActiveDir: URL { geminiDir.appendingPathComponent("code_tracker/active") }

    private var dirWatcher: DispatchSourceFileSystemObject?
    private var dirDescriptor: Int32 = -1
    private var scanTimer: Timer?
    private var debounceWork: DispatchWorkItem?

    private init() {}

    // MARK: - Lifecycle

    func start() {
        checkInstalled()
        guard isInstalled else {
            TNLog.info("[Antigravity] Not installed — skipping start", category: .monitor)
            return
        }
        scanSessions()
        watchDirectory()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
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
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let appInstalled = fm.fileExists(atPath: "/Applications/Antigravity.app")
                        || fm.fileExists(atPath: "\(home)/Applications/Antigravity.app")
        isInstalled = appInstalled && fm.fileExists(atPath: geminiDir.path)
    }

    // MARK: - Directory Watching

    private func watchDirectory() {
        dirDescriptor = Darwin.open(brainDir.path, O_EVTONLY)
        guard dirDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirDescriptor,
            eventMask: [.write, .extend],
            queue: .global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            self?.debounceWork?.cancel()
            let work = DispatchWorkItem {
                Task { @MainActor in self?.scanSessions() }
            }
            self?.debounceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
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

    // MARK: - Scanning

    private func markActivity() {
        guard isAppRunning else { return }
        isActivelyConsuming = true
        activityTimer?.invalidate()
        activityTimer = Timer.scheduledTimer(withTimeInterval: activityTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.isActivelyConsuming = false }
        }
    }

    private var isAppRunning: Bool {
        let apps = NSWorkspace.shared.runningApplications
        return apps.contains { app in
            let id = app.bundleIdentifier ?? ""
            return id == "com.google.Antigravity"
                || app.localizedName == "Antigravity"
        }
    }

    private func scanSessions() {
        let brain = self.brainDir
        let codeActive = self.codeTrackerActiveDir
        let prevTotal = totalSessions

        Task.detached(priority: .utility) {
            let result = Self.scanSessionsSync(brainDir: brain, codeActiveDir: codeActive)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.totalSessions = result.total
                self.monthlySessions = result.monthly
                self.todaySessions = result.today
                if result.recentEditWithinActivityWindow || result.total > prevTotal {
                    self.markActivity()
                }
            }
        }
    }

    private struct ScanResult {
        var total: Int = 0
        var monthly: Int = 0
        var today: Int = 0
        var recentEditWithinActivityWindow: Bool = false
    }

    private nonisolated static func scanSessionsSync(brainDir: URL, codeActiveDir: URL) -> ScanResult {
        let fm = FileManager.default
        var result = ScanResult()
        let monthStart = currentMonthStart()
        let dayStart = Calendar.current.startOfDay(for: Date())
        let activityCutoff = Date().addingTimeInterval(-30)

        // Each brain/<UUID>/ dir is one Antigravity task session. Use the dir's
        // mtime as the session timestamp.
        if let sessionDirs = try? fm.contentsOfDirectory(
            at: brainDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for dir in sessionDirs {
                let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard isDir else { continue }
                result.total += 1
                let modDate = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if modDate >= monthStart { result.monthly += 1 }
                if modDate >= dayStart   { result.today   += 1 }
            }
        }

        // "Actively consuming" = any code-edit file under code_tracker/active/
        // touched in the last 30s. Walk one level deep (project dirs) to grab
        // file mtimes without recursing the whole tree.
        if fm.fileExists(atPath: codeActiveDir.path),
           let projectDirs = try? fm.contentsOfDirectory(at: codeActiveDir, includingPropertiesForKeys: nil) {
            outer: for project in projectDirs {
                let files = (try? fm.contentsOfDirectory(
                    at: project,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                for f in files {
                    let modDate = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    if modDate >= activityCutoff {
                        result.recentEditWithinActivityWindow = true
                        break outer
                    }
                }
            }
        }

        return result
    }

    private nonisolated static func currentMonthStart() -> Date {
        let cal = Calendar.current
        let components = cal.dateComponents([.year, .month], from: Date())
        return cal.date(from: components) ?? Date()
    }

    // MARK: - Usage conversion

    /// Daily soft cap for the arc — 3 sessions/day is a reasonable active-user baseline
    /// for a code-assist tool (each session is typically a multi-step task).
    private let dailyCap = 3

    func toProviderUsage() -> ProviderUsage {
        let pct = min(Double(todaySessions) / Double(dailyCap) * 100, 100)
        return ProviderUsage(
            provider: .antigravity,
            billingType: .localUsage,
            window: .daily,
            percentage: pct,
            resetsAt: nil,
            tokensUsed: todaySessions,
            tokensLimit: dailyCap,
            costUsedUSD: nil,
            costLimitUSD: nil,
            modelBreakdown: modelBreakdown,
            fetchedAt: Date(),
            isActivelyConsuming: isActivelyConsuming
        )
    }
}
