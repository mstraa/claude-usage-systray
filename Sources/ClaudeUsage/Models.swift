import Foundation

// MARK: - Severity

/// How close a limit is to being exhausted. Drives the menu bar colour.
enum Severity: Int, Comparable {
    case normal = 0
    case warning = 1
    case critical = 2

    static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Derived from the percentage alone. The API reports a `severity` string too, but it
    /// stays "normal" well past the point where a warning is useful, so percentage leads
    /// and the API string can only escalate (see `Severity.combining`).
    static func forPercent(_ percent: Double) -> Severity {
        if percent >= 90 { return .critical }
        if percent >= 75 { return .warning }
        return .normal
    }

    /// The API sends free-form strings ("normal", and unknown values we have not observed).
    /// Anything unrecognised is treated as a warning rather than dropped on the floor.
    static func forAPIString(_ raw: String?) -> Severity {
        guard let raw = raw?.lowercased(), !raw.isEmpty else { return .normal }
        if raw == "normal" || raw == "ok" || raw == "none" { return .normal }
        if raw.contains("exceed") || raw.contains("critical") || raw.contains("reached")
            || raw.contains("exhaust") || raw.contains("block") { return .critical }
        return .warning
    }

    static func combining(percent: Double, apiSeverity: String?) -> Severity {
        max(forPercent(percent), forAPIString(apiSeverity))
    }
}

// MARK: - Presentation model

/// One rate-limit window, normalised for display.
struct LimitInfo: Identifiable, Equatable {
    let id: String
    /// Human label, e.g. "Session", "All models", "Fable".
    let label: String
    let percent: Double
    let resetsAt: Date?
    let severity: Severity
    let isActive: Bool

    var fraction: Double { min(max(percent / 100, 0), 1) }
}

/// A complete, normalised view of the usage endpoint's response.
struct UsageSnapshot: Equatable {
    /// The rolling 5-hour window.
    var session: LimitInfo?
    /// The 7-day window across all models.
    var weeklyAll: LimitInfo?
    /// Per-model 7-day windows (e.g. Opus-only), when the account has them.
    var weeklyScoped: [LimitInfo]
    var fetchedAt: Date

    var isEmpty: Bool { session == nil && weeklyAll == nil && weeklyScoped.isEmpty }

    /// Worst severity anywhere in the snapshot, used to tint the menu bar.
    var overallSeverity: Severity {
        var worst = Severity.normal
        for limit in ([session, weeklyAll].compactMap { $0 } + weeklyScoped) {
            worst = max(worst, limit.severity)
        }
        return worst
    }
}

// MARK: - Wire format

/// Mirrors `GET /api/oauth/usage`. Unknown keys are ignored, and every field the app does
/// not strictly need is optional, so a server-side addition or a null cannot break parsing.
struct UsageResponse: Decodable {
    let limits: [WireLimit]?
    let fiveHour: WireWindow?
    let sevenDay: WireWindow?

    struct WireLimit: Decodable {
        let kind: String?
        let group: String?
        let percent: Double?
        let severity: String?
        let resetsAt: String?
        let isActive: Bool?
        let scope: WireScope?
    }

    struct WireScope: Decodable {
        let model: WireModel?
        // `surface` is deliberately not decoded: it has been null in every observed
        // response and its shape is unknown, so declaring it risks a decode failure.
    }

    struct WireModel: Decodable {
        let id: String?
        let displayName: String?
    }

    struct WireWindow: Decodable {
        let utilization: Double?
        let resetsAt: String?
    }
}

// MARK: - Normalisation

extension UsageSnapshot {
    /// Builds the display model from the wire response.
    ///
    /// `limits[]` is the primary source because it is the typed, extensible shape and is
    /// the only one carrying per-model scopes. The top-level `five_hour` / `seven_day`
    /// objects are used as a fallback for whichever window `limits[]` did not provide.
    static func from(_ response: UsageResponse, now: Date) -> UsageSnapshot {
        var session: LimitInfo?
        var weeklyAll: LimitInfo?
        var scoped: [LimitInfo] = []

        for (index, wire) in (response.limits ?? []).enumerated() {
            let percent = wire.percent ?? 0
            let resetsAt = wire.resetsAt.flatMap(ISO8601.parse)
            let severity = Severity.combining(percent: percent, apiSeverity: wire.severity)
            let isActive = wire.isActive ?? false

            switch wire.kind {
            case "session":
                session = LimitInfo(id: "session", label: "Session", percent: percent,
                                    resetsAt: resetsAt, severity: severity, isActive: isActive)
            case "weekly_all":
                weeklyAll = LimitInfo(id: "weekly_all", label: "All models", percent: percent,
                                      resetsAt: resetsAt, severity: severity, isActive: isActive)
            case "weekly_scoped":
                let name = wire.scope?.model?.displayName
                    ?? wire.scope?.model?.id
                    ?? "Scoped"
                scoped.append(LimitInfo(id: "scoped-\(wire.scope?.model?.id ?? name)-\(index)",
                                        label: name, percent: percent, resetsAt: resetsAt,
                                        severity: severity, isActive: isActive))
            default:
                // Unknown kinds are ignored rather than guessed at; the fallback below
                // still covers the two windows the app actually displays.
                continue
            }
        }

        if session == nil, let window = response.fiveHour, let utilization = window.utilization {
            session = LimitInfo(id: "session", label: "Session", percent: utilization,
                                resetsAt: window.resetsAt.flatMap(ISO8601.parse),
                                severity: Severity.forPercent(utilization), isActive: false)
        }
        if weeklyAll == nil, let window = response.sevenDay, let utilization = window.utilization {
            weeklyAll = LimitInfo(id: "weekly_all", label: "All models", percent: utilization,
                                  resetsAt: window.resetsAt.flatMap(ISO8601.parse),
                                  severity: Severity.forPercent(utilization), isActive: false)
        }

        scoped.sort { $0.percent > $1.percent }

        return UsageSnapshot(session: session, weeklyAll: weeklyAll,
                             weeklyScoped: scoped, fetchedAt: now)
    }
}

// MARK: - Date parsing

enum ISO8601 {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// The API sends 6 fractional digits ("...:00.216074+00:00"), which
    /// `ISO8601DateFormatter` does not reliably accept, so stripping them is the path that
    /// actually works. Sub-second precision is meaningless for a reset time.
    static func parse(_ raw: String) -> Date? {
        if let date = fractional.date(from: raw) { return date }
        if let date = plain.date(from: raw) { return date }

        guard let dot = raw.firstIndex(of: ".") else { return nil }
        var end = raw.index(after: dot)
        while end < raw.endIndex, raw[end].isNumber {
            end = raw.index(after: end)
        }
        let stripped = String(raw[raw.startIndex..<dot]) + String(raw[end...])
        return plain.date(from: stripped) ?? fractional.date(from: stripped)
    }
}
