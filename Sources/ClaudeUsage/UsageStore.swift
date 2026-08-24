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
    /// Bumped on a timer so relative times ("in 2h13m") re-render without a network call.
    @Published private(set) var clockTick = 0

    static let pollInterval: TimeInterval = 60

    private var pollTimer: Timer?
    private var inFlight: Task<Void, Never>?

    var isStale: Bool { lastError != nil && snapshot != nil }

    deinit {
        pollTimer?.invalidate()
        inFlight?.cancel()
    }

    func start() {
        refresh()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.clockTick &+= 1
                self?.refresh()
            }
        }
        // Common modes so polling continues while the popover or a menu is tracking events.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func refresh() {
        guard inFlight == nil else { return }
        isRefreshing = true

        inFlight = Task { [weak self] in
            let result: Result<UsageSnapshot, Error>
            do {
                result = .success(try await UsageAPI.fetch())
            } catch {
                result = .failure(error)
            }

            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                switch result {
                case .success(let snapshot):
                    self.snapshot = snapshot
                    self.lastError = nil
                case .failure(let error):
                    self.lastError = (error as? UsageError) ?? .transport(error.localizedDescription)
                }
                self.isRefreshing = false
                self.inFlight = nil
            }
        }
    }
}
