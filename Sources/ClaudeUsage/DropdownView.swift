import SwiftUI

extension Severity {
    var tint: Color {
        switch self {
        case .normal: return Color.accentColor
        case .warning: return Color.orange
        case .critical: return Color.red
        }
    }
}

struct DropdownView: View {
    @ObservedObject var store: UsageStore
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?
    @State private var needsApproval = LoginItem.requiresApproval

    private static let width: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if let snapshot = store.snapshot {
                content(for: snapshot)
            } else if store.lastError == nil {
                loading
            }

            if let error = store.lastError {
                errorBanner(error)
            }

            Divider()
            footer
        }
        .frame(width: Self.width)
        // The hosting controller is built once and reused, so this state survives every
        // close/open. Re-reading it here keeps a one-shot failure message from outliving the
        // condition that caused it.
        .onAppear { syncLoginItemState(clearingError: true) }
    }

    /// A bare error reads as permanent. Naming the next attempt shows it is being handled.
    private func errorDetail(_ error: UsageError) -> String {
        var text = error.localizedDescription
        if store.nextFetchAt > Date() {
            text += " Retrying \(Format.relative(to: store.nextFetchAt))."
        }
        return text
    }

    private func syncLoginItemState(clearingError: Bool) {
        if clearingError { loginItemError = nil }
        launchAtLogin = LoginItem.isEnabled
        needsApproval = LoginItem.requiresApproval
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 6) {
            Text("Claude Usage")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(action: { store.refresh(force: true) }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .opacity(store.isRefreshing ? 0.35 : 1)
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshing)
            .help("Refresh now")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var loading: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading usage…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private func content(for snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let session = snapshot.session {
                LimitBlock(title: "Session · 5 hours", limit: session, tick: store.clockTick)
            }
            if let weekly = snapshot.weeklyAll {
                LimitBlock(title: "Week · all models", limit: weekly, tick: store.clockTick)
            }
            if !snapshot.weeklyScoped.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    SectionLabel(text: "Week · by model", isActive: false)
                    ForEach(snapshot.weeklyScoped) { limit in
                        ModelRow(limit: limit)
                    }
                }
            }
            if snapshot.isEmpty {
                Text("No limit data reported for this account.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func errorBanner(_ error: UsageError) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: store.snapshot == nil ? "exclamationmark.triangle.fill" : "clock.badge.exclamationmark")
                .font(.system(size: 11))
                .foregroundStyle(store.snapshot == nil ? Color.orange : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.snapshot == nil ? "Can't read usage" : "Showing last known values")
                    .font(.system(size: 11, weight: .medium))
                Text(errorDetail(error))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(store.clockTick)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.04))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin },
                set: { newValue in
                    do {
                        try LoginItem.setEnabled(newValue)
                        loginItemError = nil
                    } catch {
                        loginItemError = error.localizedDescription
                    }
                    syncLoginItemState(clearingError: false)
                }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .disabled(!LoginItem.isAvailable)

            // `needsApproval` is re-read from the system rather than latched, so it clears
            // itself once the user approves the item.
            if let note = loginItemError ?? (needsApproval ? LoginItemError.needsApproval.errorDescription : nil) {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !LoginItem.isAvailable {
                Text("Available when running the built app bundle.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if let updated = store.snapshot?.fetchedAt {
                    Text("Updated \(Format.clock(updated))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .id(store.clockTick)
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("Quit Claude Usage")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Pieces

private struct SectionLabel: View {
    let text: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text(text.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.4)
            if isActive {
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 4, height: 4)
                    .help("Currently the binding limit")
            }
            Spacer(minLength: 0)
        }
    }
}

private struct LimitBlock: View {
    let title: String
    let limit: LimitInfo
    /// Only present so a store tick invalidates the relative-time text.
    let tick: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: title, isActive: limit.isActive)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Format.percent(limit.percent))
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(limit.severity == .normal ? Color.primary : limit.severity.tint)
                Spacer(minLength: 0)
                if let resetsAt = limit.resetsAt {
                    Text(Format.relative(to: resetsAt))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .id(tick)
                }
            }

            UsageBar(fraction: limit.fraction, tint: limit.severity.tint)

            if let resetsAt = limit.resetsAt {
                Text("Resets \(Format.resetPhrase(resetsAt))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .id(tick)
            }
        }
    }
}

private struct ModelRow: View {
    let limit: LimitInfo

    var body: some View {
        HStack(spacing: 8) {
            Text(limit.label)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 6)
            UsageBar(fraction: limit.fraction, tint: limit.severity.tint, height: 4)
                .frame(width: 90)
            Text(Format.percent(limit.percent))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }
}

private struct UsageBar: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(tint)
                    // A non-zero floor keeps a sliver visible at 1–2%, but a true 0 stays empty.
                    .frame(width: fraction <= 0 ? 0 : max(3, geometry.size.width * fraction))
            }
        }
        .frame(height: height)
    }
}
