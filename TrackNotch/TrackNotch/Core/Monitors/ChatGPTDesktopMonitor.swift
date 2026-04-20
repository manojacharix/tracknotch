import AppKit
import Foundation

/// Monitors ~/Library/Application Support/com.openai.chat/conversations-*/ for ChatGPT Desktop.
/// Zero auth — reads local conversation files.
@MainActor
final class ChatGPTDesktopMonitor: ObservableObject {
    static let shared = ChatGPTDesktopMonitor()

    @Published private(set) var isInstalled = false
    @Published private(set) var totalConversations: Int = 0
    @Published private(set) var monthlyConversations: Int = 0
    @Published private(set) var todayConversations: Int = 0
    @Published private(set) var modelBreakdown: [ModelUsage] = []
    @Published private(set) var isActivelyConsuming = false

    private var activityTimer: Timer?
    private let activityTimeout: TimeInterval = 30

    private let supportDir: URL = {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("com.openai.chat")
    }()

    private var dirWatcher: DispatchSourceFileSystemObject?
    private var dirDescriptor: Int32 = -1
    private var scanTimer: Timer?

    private init() {}

    // MARK: - Lifecycle

    func start() {
        checkInstalled()
        guard isInstalled else { print("[ChatGPT] Not installed — skipping start"); return }
        scanConversations()
        watchDirectory()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scanConversations() }
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
        // Antigravity is the ChatGPT-based desktop client on this machine.
        // Also check for the upstream ChatGPT.app in case the user has that instead.
        let appInstalled = fm.fileExists(atPath: "/Applications/Antigravity.app")
                        || fm.fileExists(atPath: "\(home)/Applications/Antigravity.app")
                        || fm.fileExists(atPath: "/Applications/ChatGPT.app")
                        || fm.fileExists(atPath: "\(home)/Applications/ChatGPT.app")
        isInstalled = appInstalled && fm.fileExists(atPath: supportDir.path)
    }

    // MARK: - Directory Watching

    private func watchDirectory() {
        dirDescriptor = Darwin.open(supportDir.path, O_EVTONLY)
        guard dirDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirDescriptor,
            eventMask: [.write, .extend],
            queue: .global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.scanConversations()
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

    // MARK: - Scanning

    private func markActivity() {
        // Only mark as active if the app is actually running
        guard isAppRunning else { return }
        isActivelyConsuming = true
        activityTimer?.invalidate()
        activityTimer = Timer.scheduledTimer(withTimeInterval: activityTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.isActivelyConsuming = false }
        }
    }

    /// Check if ChatGPT/Antigravity is currently running
    private var isAppRunning: Bool {
        let apps = NSWorkspace.shared.runningApplications
        return apps.contains { app in
            let id = app.bundleIdentifier ?? ""
            return id == "com.openai.chat"
                || id == "com.openai.chatgpt"
                || id == "com.openai.antigravity"
                || app.localizedName == "Antigravity"
                || app.localizedName == "ChatGPT"
        }
    }

    private func scanConversations() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: supportDir.path) else { return }

        let prevConversations = totalConversations
        var allConversations = 0
        var thisMonthConversations = 0
        var thisDayConversations = 0
        let monthStart = Self.currentMonthStart()
        let dayStart   = Calendar.current.startOfDay(for: Date())

        // ChatGPT desktop stores conversations in conversations-<uuid>/ directories
        let contents = (try? fm.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil)) ?? []
        for dir in contents where dir.lastPathComponent.hasPrefix("conversations") {
            let items = (try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: []
            )) ?? []
            let convFiles = items.filter { $0.pathExtension == "data" || $0.pathExtension == "json" }
            allConversations += convFiles.count
            for url in convFiles {
                let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if modDate >= monthStart { thisMonthConversations += 1 }
                if modDate >= dayStart   { thisDayConversations   += 1 }
            }
        }

        totalConversations = allConversations
        monthlyConversations = thisMonthConversations
        todayConversations = thisDayConversations

        if allConversations > prevConversations { markActivity() }
    }

    private static func currentMonthStart() -> Date {
        let cal = Calendar.current
        let components = cal.dateComponents([.year, .month], from: Date())
        return cal.date(from: components) ?? Date()
    }

    // MARK: - Usage conversion

    // Daily soft cap for the arc — 5 conversations/day is a reasonable active-user baseline.
    // Not a hard limit; just makes the arc visually meaningful at normal usage volumes.
    private let dailyCap = 5

    func toProviderUsage() -> ProviderUsage {
        let pct = min(Double(todayConversations) / Double(dailyCap) * 100, 100)
        return ProviderUsage(
            provider: .chatGPTDesktop,
            billingType: .localUsage,
            window: .daily,
            percentage: pct,
            resetsAt: nil,
            tokensUsed: todayConversations,
            tokensLimit: dailyCap,
            costUsedUSD: nil,
            costLimitUSD: nil,
            modelBreakdown: modelBreakdown,
            fetchedAt: Date(),
            isActivelyConsuming: isActivelyConsuming
        )
    }
}
