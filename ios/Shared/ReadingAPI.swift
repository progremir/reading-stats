import Foundation

/// What /api/widget returns.
struct ReadingSnapshot: Codable, Sendable {
    struct Book: Codable, Sendable {
        let title: String
        let authors: String
        let progress: Double
        let id: String
    }

    let today: Int
    let week: Int
    let month: Int
    let streak: Int
    let last7: [Int]
    let updated: String?
    let book: Book?
    /// Seconds read per day, oldest first, ending today (about 26 weeks).
    var days: [Int]? = nil
    var first_day: String? = nil

    static let placeholder = ReadingSnapshot(
        today: 1_920, week: 9_300, month: 31_000, streak: 6,
        last7: [1_200, 2_400, 0, 1_800, 3_000, 900, 1_920], updated: nil,
        book: Book(title: "The Way of Kings", authors: "Brandon Sanderson", progress: 0.42, id: ""),
        days: (0..<182).map { i in [0, 0, 600, 1_200, 2_400, 0, 3_900, 900][(i * 7 + i / 5) % 8] }
    )
}

// UserDefaults is thread-safe; it just isn't marked Sendable.
nonisolated(unsafe) private let groupDefaults = UserDefaults(
    suiteName: Bundle.main.object(forInfoDictionaryKey: "ReadingAppGroup") as? String)

/// The reading-stats server this phone uses, chosen in the app and shared with the widgets.
enum ServerStore {
    private static var defaults: UserDefaults? { groupDefaults }

    static var url: URL? { defaults?.string(forKey: "serverURL").flatMap(URL.init(string:)) }

    static func save(_ url: URL) {
        defaults?.set(url.absoluteString, forKey: "serverURL")
    }

    static func clear() {
        defaults?.removeObject(forKey: "serverURL")
    }

    /// Addresses to try for what someone typed: "read.example.com" → https://read.example.com/, then
    /// http://read.example.com/ (a server on the home network); a typed scheme is kept as is.
    static func candidates(_ text: String) -> [URL] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let typed = text.contains("://") ? [text] : ["https://" + text, "http://" + text]
        return typed.compactMap { text in
            guard var parts = URLComponents(string: text), let host = parts.host, !host.isEmpty,
                  parts.scheme == "https" || parts.scheme == "http" else { return nil }
            parts.path = "/"
            parts.query = nil
            parts.fragment = nil
            return parts.url
        }
    }

    /// True when the address answers like a reading-stats server.
    static func check(_ url: URL) async -> Bool {
        var request = URLRequest(url: url.appending(path: "healthz"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200 && data == Data("ok".utf8)
    }
}

/// The widget token the app got when someone signed in, shared with the widgets through the App Group.
enum TokenStore {
    private static var defaults: UserDefaults? { groupDefaults }

    static var token: String? { defaults?.string(forKey: "widgetToken") }
    static var account: String? { defaults?.string(forKey: "widgetAccount") }

    static func save(token: String, account: String) {
        defaults?.set(token, forKey: "widgetToken")
        defaults?.set(account, forKey: "widgetAccount")
    }

    static func clear() {
        defaults?.removeObject(forKey: "widgetToken")
        defaults?.removeObject(forKey: "widgetAccount")
    }
}

enum ReadingAPI {
    static func fetch() async throws -> ReadingSnapshot {
        guard let baseURL = ServerStore.url, let token = TokenStore.token else {
            throw URLError(.userAuthenticationRequired)
        }
        var request = URLRequest(url: baseURL.appending(path: "api/widget"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(ReadingSnapshot.self, from: data)
    }
}

enum Format {
    /// "32 min", "1.5 h", "12 h"
    static func duration(_ seconds: Int) -> (value: String, unit: String) {
        let minutes = Int((Double(seconds) / 60).rounded())
        if minutes < 60 { return ("\(minutes)", "min") }
        let hours = Double(seconds) / 3600
        return (hours >= 10 ? "\(Int(hours.rounded()))" : String(format: "%.1f", hours), "h")
    }

    static func durationText(_ seconds: Int) -> String {
        let d = duration(seconds)
        return "\(d.value) \(d.unit)"
    }
}
