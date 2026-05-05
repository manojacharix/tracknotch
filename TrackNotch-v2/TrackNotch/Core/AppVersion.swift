import Foundation

enum AppVersion {
    static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}

// MARK: - Update checker (polls GitHub Releases API)

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    enum State {
        case idle
        case checking
        case upToDate
        case available(version: String, url: URL)
        case failed
    }

    @Published var state: State = .idle

    private let releasesURL = URL(string: "https://api.github.com/repos/manojacharix/tracknotch/releases/latest")!

    private init() {}

    func check() {
        guard case .idle = state else { return }
        state = .checking
        Task {
            await fetch()
        }
    }

    func reset() { state = .idle }

    private func fetch() async {
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String,
                  let htmlURL = json["html_url"] as? String,
                  let url = URL(string: htmlURL) else {
                state = .failed
                return
            }
            // Strip leading "v" from tag (e.g. "v1.0.1" → "1.0.1")
            let latest = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            let current = AppVersion.short
            if isNewer(latest, than: current) {
                state = .available(version: latest, url: url)
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed
        }
    }

    /// Simple semver comparison — returns true if `a` > `b`.
    private func isNewer(_ a: String, than b: String) -> Bool {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        let maxLen = max(aParts.count, bParts.count)
        for i in 0..<maxLen {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }
}
