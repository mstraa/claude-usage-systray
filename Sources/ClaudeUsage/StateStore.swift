import Foundation

/// The last known snapshot plus the backoff schedule, persisted across launches.
struct PersistedState: Codable {
    var snapshot: UsageSnapshot?
    var nextFetchAt: Date
    var consecutiveFailures: Int
}

/// Small on-disk cache so a restart — or a crash — does not leave the app with nothing to
/// show until the next successful fetch. That matters most exactly when fetching is failing.
///
/// Only derived usage figures and timestamps are written: percentages, reset dates and the
/// retry schedule. No credential ever reaches this file.
enum StateStore {

    private static let directoryName = "ClaudeUsage"
    private static let fileName = "state.json"

    private static var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent(directoryName, isDirectory: true)
                   .appendingPathComponent(fileName)
    }

    // The default date strategy is used deliberately: `.iso8601` truncates sub-second
    // precision, so a saved snapshot would not round-trip to an equal value.
    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()

    static func load() -> PersistedState? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        // A cache that fails to decode (format change, truncated write) is simply ignored;
        // it must never stop the app from starting.
        return try? decoder.decode(PersistedState.self, from: data)
    }

    static func save(_ state: PersistedState) {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try encoder.encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Persistence is a convenience, not a requirement — a failure here must not
            // disturb a perfectly working live session.
        }
    }
}
