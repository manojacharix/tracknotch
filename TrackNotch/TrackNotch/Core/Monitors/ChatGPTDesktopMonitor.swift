import Foundation

/// Monitors ~/Library/Application Support/com.openai.chat/conversations-*/ for ChatGPT Desktop.
/// Zero auth — reads local conversation files.
@MainActor
final class ChatGPTDesktopMonitor: ObservableObject {
    static let shared = ChatGPTDesktopMonitor()

    @Published private(set) var isInstalled = false
    @Published private(set) var totalConversations: Int = 0
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
        guard isInstalled else { return }
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
        isInstalled = FileManager.default.fileExists(atPath: supportDir.path)
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
        isActivelyConsuming = true
        activityTimer?.invalidate()
        activityTimer = Timer.scheduledTimer(withTimeInterval: activityTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.isActivelyConsuming = false }
        }
    }

    private func scanConversations() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: supportDir.path) else { return }

        let prevConversations = totalConversations
        var conversations = 0
        let models: [String: Int] = [:]

        // ChatGPT desktop stores conversations in conversations-<uuid>/ directories
        let contents = (try? fm.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.lastPathComponent.hasPrefix("conversations") {
            if let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                conversations += items.filter { $0.pathExtension == "json" }.count
            }
        }

        totalConversations = conversations
        modelBreakdown = models.map { ModelUsage(modelName: $0.key, tokensUsed: $0.value, costUSD: nil) }

        if conversations > prevConversations { markActivity() }
    }

    // MARK: - Usage conversion

    func toProviderUsage() -> ProviderUsage {
        ProviderUsage(
            provider: .chatGPTDesktop,
            billingType: .localUsage,
            window: .monthly,
            percentage: 0,
            resetsAt: nil,
            tokensUsed: totalConversations,
            tokensLimit: nil,
            costUsedUSD: nil,
            costLimitUSD: nil,
            modelBreakdown: modelBreakdown,
            fetchedAt: Date(),
            isActivelyConsuming: isActivelyConsuming
        )
    }
}
