import Foundation
import Combine

/// Owns the polling loop and the latest known usage state.
///
/// A failed refresh never discards the last good snapshot: the menu bar keeps showing the
/// most recent numbers, marked stale, rather than blanking out on a transient network blip.
@MainActor
final class UsageStore: ObservableObject {

    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var lastError: UsageError?
    @Published private(set) var isRefreshing = false
    /// When the next automatic attempt is due. Surfaced so the UI can say "retrying in 6m"
    /// instead of leaving a failure looking permanent.
    @Published private(set) var nextFetchAt = Date.distantPast
    /// Bumped on a timer so relative times ("in 2h13m") re-render without a network call.
    @Published private(set) var clockTick = 0

    /// Deliberately unhurried. The endpoint rate-limits hard — a 60s poll exhausted it and
    /// stayed 429 through five minutes of silence — and Claude Code polls the same endpoint
    /// on the same account, so this app's requests are additive. Usage percentages only move
    /// when Claude is actually used, so minutes of staleness cost nothing.
    static let pollInterval: TimeInterval = 300
    /// Ceiling for the exponential backoff after repeated failures.
    static let maxBackoff: TimeInterval = 1800
    /// Floor between user-initiated refreshes, so holding the button cannot hammer the API.
    static let manualRefreshFloor: TimeInterval = 15
    /// How often the run loop wakes to update countdowns and check whether a fetch is due.
    private static let tickInterval: TimeInterval = 30

    private var tickTimer: Timer?
    private var inFlight: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var lastAttemptAt: Date?

    var isStale: Bool { lastError != nil && snapshot != nil }

    deinit {
        tickTimer?.invalidate()
        inFlight?.cancel()
    }

    func start() {
        // Restore before the first fetch: a cold start that cannot reach the API — which is
        // exactly what a rate limit or a crash-restart produces — would otherwise leave the
        // user with no numbers at all.
        if let saved = StateStore.load() {
            snapshot = saved.snapshot
            consecutiveFailures = saved.consecutiveFailures
            nextFetchAt = saved.nextFetchAt
            // Restored figures are from a previous run and not yet re-verified, so they are
            // presented as last-known rather than live until a fetch actually succeeds.
            if saved.snapshot != nil {
                lastError = .staleCache
            }
        }
        // Relaunching must not punch through an active backoff, or quitting and reopening
        // becomes a way to hammer a rate-limited endpoint.
        refresh(force: Date() >= nextFetchAt)
        // One steady ticker drives both the countdown text and the fetch schedule, so a
        // backoff never has to reschedule a timer.
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.clockTick &+= 1
                self.refresh()
            }
        }
        // Common modes so polling continues while the popover or a menu is tracking events.
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    /// - Parameter force: bypass the backoff schedule for an explicit user request. Still
    ///   subject to `manualRefreshFloor`, since forcing more requests at a rate-limited
    ///   endpoint only prolongs the block.
    func refresh(force: Bool = false) {
        guard inFlight == nil else { return }

        let now = Date()
        if force {
            if let last = lastAttemptAt, now.timeIntervalSince(last) < Self.manualRefreshFloor { return }
        } else if now < nextFetchAt {
            return
        }

        lastAttemptAt = now
        isRefreshing = true

        inFlight = Task { [weak self] in
            let result: Result<UsageSnapshot, Error>
            do {
                result = .success(try await UsageAPI.fetch())
            } catch {
                result = .failure(error)
            }

            guard let self else { return }
            await MainActor.run {
                self.apply(result)
                self.isRefreshing = false
                self.inFlight = nil
            }
        }
    }

    private func apply(_ result: Result<UsageSnapshot, Error>) {
        switch result {
        case .success(let snapshot):
            self.snapshot = snapshot
            lastError = nil
            consecutiveFailures = 0
            nextFetchAt = Date().addingTimeInterval(Self.pollInterval)

        case .failure(let error):
            let usageError = (error as? UsageError) ?? .transport(error.localizedDescription)
            lastError = usageError
            consecutiveFailures += 1
            nextFetchAt = Date().addingTimeInterval(backoffDelay(for: usageError))
        }
        persist()
    }

    private func persist() {
        StateStore.save(PersistedState(snapshot: snapshot,
                                       nextFetchAt: nextFetchAt,
                                       consecutiveFailures: consecutiveFailures))
    }

    /// Exponential backoff from the poll interval. Without this a rate-limited endpoint is
    /// retried forever at the same cadence, which is what keeps the block alive.
    private func backoffDelay(for error: UsageError) -> TimeInterval {
        if case .rateLimited(let retryAfter) = error, let retryAfter {
            return min(max(retryAfter, Self.pollInterval), Self.maxBackoff)
        }
        let exponent = min(max(consecutiveFailures - 1, 0), 8)
        return min(Self.pollInterval * pow(2, Double(exponent)), Self.maxBackoff)
    }
}
