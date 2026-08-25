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

    /// Cadence while the figures are visibly moving: the user is working, so the menu bar
    /// has to track it or it reads as dead.
    static let activePollInterval: TimeInterval = 240
    /// Cadence once the figures have stopped moving. Polling an unchanging number costs
    /// requests and buys nothing — and the endpoint rate-limits hard, with Claude Code
    /// polling it on the same account, so idle load is what should be cut.
    static let idlePollInterval: TimeInterval = 900
    /// Consecutive unchanged polls before dropping to the idle cadence.
    private static let unchangedPollsBeforeSlowing = 2
    /// Starting point for the failure backoff.
    static let backoffBase: TimeInterval = 300
    /// Opening the dropdown refetches only if the figures are older than this.
    static let onDemandFreshness: TimeInterval = 120
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
    /// Drives the active/idle cadence switch.
    private var unchangedPolls = 0
    /// Hard gate after a failure: nothing fetches before this, not even the user, because
    /// extra requests at a rate-limited endpoint only prolong the block.
    private var backoffUntil = Date.distantPast
    /// The normal background cadence, which the on-demand paths are allowed to pre-empt.
    private var nextScheduledFetch = Date.distantPast

    enum RefreshTrigger {
        /// The background timer.
        case scheduled
        /// The dropdown was opened — fetch only if the figures are not already fresh.
        case onDemand
        /// The refresh button.
        case manual
    }

    var isStale: Bool { lastError != nil && snapshot != nil }
    /// True while a failure backoff is still in force, so the UI can explain why the refresh
    /// button is inert rather than appearing to ignore the click.
    var isBackingOff: Bool { Date() < backoffUntil }

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
            nextScheduledFetch = saved.nextFetchAt
            // Only a prior failure justifies gating the user out; a merely-due schedule does not.
            backoffUntil = saved.consecutiveFailures > 0 ? saved.nextFetchAt : .distantPast
            // Restored figures are from a previous run and not yet re-verified, so they are
            // presented as last-known rather than live until a fetch actually succeeds.
            if saved.snapshot != nil {
                lastError = .staleCache
            }
        }
        // `.onDemand` rather than a forced fetch: relaunching must not punch through an
        // active backoff, or quitting and reopening becomes a way to hammer the endpoint.
        // `.scheduled`, not `.onDemand`: a launch is not someone looking at the dropdown, so
        // it must obey the normal cadence. Otherwise every restart buys a free request, and a
        // crash-restart loop becomes a request storm. This still fetches immediately when the
        // app has been closed long enough for the schedule to have come due.
        refresh(.scheduled)
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

    func refresh(_ trigger: RefreshTrigger = .scheduled) {
        guard inFlight == nil else { return }

        let now = Date()
        // No trigger may punch through an active backoff.
        guard now >= backoffUntil else { return }

        switch trigger {
        case .scheduled:
            guard now >= nextScheduledFetch else { return }
        case .onDemand:
            if let snapshot, now.timeIntervalSince(snapshot.fetchedAt) < Self.onDemandFreshness { return }
        case .manual:
            if let last = lastAttemptAt, now.timeIntervalSince(last) < Self.manualRefreshFloor { return }
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
        case .success(let fresh):
            // Compared before the assignment, so this sees the previous figures.
            unchangedPolls = Self.figuresMoved(from: snapshot, to: fresh) ? 0 : unchangedPolls + 1
            snapshot = fresh
            lastError = nil
            consecutiveFailures = 0
            backoffUntil = .distantPast
            let interval = unchangedPolls >= Self.unchangedPollsBeforeSlowing
                ? Self.idlePollInterval
                : Self.activePollInterval
            nextScheduledFetch = Date().addingTimeInterval(interval)
            nextFetchAt = nextScheduledFetch

        case .failure(let error):
            let usageError = (error as? UsageError) ?? .transport(error.localizedDescription)
            lastError = usageError
            consecutiveFailures += 1
            backoffUntil = Date().addingTimeInterval(backoffDelay(for: usageError))
            nextScheduledFetch = backoffUntil
            nextFetchAt = backoffUntil
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
            return min(max(retryAfter, Self.backoffBase), Self.maxBackoff)
        }
        let exponent = min(max(consecutiveFailures - 1, 0), 8)
        return min(Self.backoffBase * pow(2, Double(exponent)), Self.maxBackoff)
    }

    /// Whether either headline figure changed, which is the signal that the user is actively
    /// consuming quota and the menu bar needs to keep up.
    private static func figuresMoved(from old: UsageSnapshot?, to new: UsageSnapshot) -> Bool {
        guard let old else { return true }
        return old.session?.percent != new.session?.percent
            || old.weeklyAll?.percent != new.weeklyAll?.percent
    }
}
