import AppKit
import SwiftUI
import Combine

/// Owns the menu bar item and the popover hanging off it.
@MainActor
final class StatusItemController {

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let store: UsageStore
    private var cancellables = Set<AnyCancellable>()
    private var outsideClickMonitor: Any?
    private var escapeKeyMonitor: Any?

    init(store: UsageStore) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        configureButton()
        configurePopover()

        // `objectWillChange` fires *before* the new value lands, so delivery is deferred by
        // one hop; rendering inline would paint the previous snapshot. The main *queue*
        // rather than the main run loop, so delivery is not held back during event tracking.
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.render() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.closePopover() }
            .store(in: &cancellables)

        render()
    }

    deinit {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let escapeKeyMonitor { NSEvent.removeMonitor(escapeKeyMonitor) }
    }

    // MARK: - Setup

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePopover() {
        let hosting = NSHostingController(rootView: DropdownView(store: store))
        // Load-bearing: NSPopover anchors from `contentSize` (default 320×320) but sizes its
        // window from the hosting view. Without this the popover renders 40pt off-centre and
        // 181pt below the status item, visibly detached.
        hosting.sizingOptions = [.preferredContentSize]

        popover.contentViewController = hosting
        popover.animates = false
        // `.transient` closes on the mouse-down that precedes the button's action, so the
        // action then reopens it and the item appears stuck. Owning dismissal explicitly
        // makes the toggle deterministic.
        popover.behavior = .applicationDefined
    }

    // MARK: - Rendering

    /// What the menu bar should show right now, resolved in one place so the label and the
    /// ring cannot disagree.
    private struct BarAppearance {
        let title: String
        /// How much of the weekly window is used, 0...1; `nil` when it is not known.
        let weeklyFraction: Double?
        /// The numbers are real but no longer known to be current.
        let dimmed: Bool
    }

    private func barAppearance() -> BarAppearance {
        // An expired sign-in is not self-healing. The figures cannot move until the user acts,
        // so continuing to show the last percentage reads as a live reading that happens to be
        // low — which is exactly how a frozen 0% gets mistaken for real usage.
        if let error = store.lastError, error.requiresUserAction {
            return BarAppearance(title: "!", weeklyFraction: nil, dimmed: false)
        }
        guard let snapshot = store.snapshot else {
            return BarAppearance(title: "", weeklyFraction: nil, dimmed: false)
        }

        let stale = store.isStale
        let now = Date()

        // Same reasoning as the session below: a stale weekly figure whose window has rolled
        // is unknowable, so the ring goes empty rather than keep the previous week's arc.
        let weeklyFraction = snapshot.weeklyAll.flatMap { weekly -> Double? in
            let rolled = weekly.resetsAt.map { $0 <= now } ?? false
            return stale && rolled ? nil : weekly.fraction
        }

        guard let session = snapshot.session else {
            return BarAppearance(title: "—", weeklyFraction: weeklyFraction, dimmed: stale)
        }

        let resetPassed = session.resetsAt.map { $0 <= now } ?? false

        // Past its own reset with no successful refresh, the percentage is not merely old —
        // the window has rolled and the real figure is unknowable, so showing the previous
        // number would be actively wrong.
        if stale && resetPassed {
            return BarAppearance(title: "—", weeklyFraction: weeklyFraction, dimmed: true)
        }

        var title = Format.percent(session.percent)
        // A reset time that has already passed names a moment in the past. This also absorbs
        // the sub-minute gap between the reset instant and the next successful poll.
        if let resetsAt = session.resetsAt, !resetPassed {
            title += " · " + Format.clock(resetsAt)
        }
        return BarAppearance(title: title, weeklyFraction: weeklyFraction, dimmed: stale)
    }

    private func render() {
        guard let button = statusItem.button else { return }

        let appearance = barAppearance()

        button.image = ringImage(fraction: appearance.weeklyFraction, dimmed: appearance.dimmed)
        // Assigning `button.title` after this would silently wipe the colour: the two
        // properties share storage.
        button.attributedTitle = NSAttributedString(
            string: appearance.title.isEmpty ? "" : " " + appearance.title,
            attributes: [
                // The menu bar font has proportional digits, so the label visibly jitters as
                // the numbers change. Monospaced digits keep the width stable.
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
                // Dynamic colours resolve at draw time against the *button's* appearance, which
                // tracks the menu bar rather than the system theme.
                .foregroundColor: appearance.dimmed ? NSColor.secondaryLabelColor : NSColor.labelColor,
            ]
        )
        button.toolTip = tooltip()
    }

    /// A ring whose arc, clockwise from 12 o'clock, is the share of the weekly window used.
    private func ringImage(fraction: Double?, dimmed: Bool) -> NSImage {
        let side: CGFloat = 14
        let lineWidth: CGFloat = 2
        // A template image is tinted by the menu bar itself and only its alpha survives, so
        // the track and the dimmed state are expressed as opacity rather than as colours.
        let strength: CGFloat = dimmed ? 0.55 : 1

        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = (side - lineWidth) / 2

            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lineWidth
            NSColor.black.withAlphaComponent(0.25 * strength).setStroke()
            track.stroke()

            if let fraction, fraction > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius,
                              startAngle: 90, endAngle: 90 - 360 * CGFloat(fraction), clockwise: true)
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                NSColor.black.withAlphaComponent(strength).setStroke()
                arc.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Claude usage"
        return image
    }

    private func tooltip() -> String {
        guard let snapshot = store.snapshot else {
            return store.lastError?.localizedDescription ?? "Loading Claude usage…"
        }
        func line(_ name: String, _ limit: LimitInfo) -> String {
            guard let resetsAt = limit.resetsAt else {
                return "\(name): \(Format.percent(limit.percent))"
            }
            return "\(name): \(Format.percent(limit.percent)) · resets \(Format.resetPhrase(resetsAt))"
        }

        var lines: [String] = []
        if let session = snapshot.session { lines.append(line("Session (5h)", session)) }
        if let weekly = snapshot.weeklyAll { lines.append(line("Week", weekly)) }
        // Only the scoped windows running high, so an account with many models does not get
        // a wall of 1% rows.
        for scoped in snapshot.weeklyScoped where scoped.severity != .normal {
            lines.append(line("Week (\(scoped.label))", scoped))
        }
        if store.isStale {
            lines.append("Last update failed at \(Format.clock(snapshot.fetchedAt)) — showing previous values.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Popover

    @objc private func togglePopover() {
        popover.isShown ? closePopover() : showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }

        store.refresh(.onDemand)

        // An accessory app can only activate itself from inside a user event; called from a
        // timer this silently fails and the popover's controls stay unresponsive.
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        startMonitors()
    }

    private func closePopover() {
        guard popover.isShown else { return }
        popover.performClose(nil)
        stopMonitors()
    }

    private func startMonitors() {
        // A global monitor only sees events in *other* processes, so clicking the status
        // button itself does not trip it and the toggle above stays authoritative.
        if outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in
                Task { @MainActor in self?.closePopover() }
            }
        }
        if escapeKeyMonitor == nil {
            escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard event.keyCode == 53 else { return event }  // Escape
                Task { @MainActor in self?.closePopover() }
                return nil
            }
        }
    }

    private func stopMonitors() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let escapeKeyMonitor {
            NSEvent.removeMonitor(escapeKeyMonitor)
            self.escapeKeyMonitor = nil
        }
    }
}
