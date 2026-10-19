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

enum ReadingAPI {
    static let baseURL = URL(string: Secrets.serverURL)!

    static func fetch() async throws -> ReadingSnapshot {
        var request = URLRequest(url: baseURL.appending(path: "api/widget"))
        request.setValue("Bearer \(Secrets.widgetToken)", forHTTPHeaderField: "Authorization")
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
