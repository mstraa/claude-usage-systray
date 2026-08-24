import AppKit

/// Entry point. This lives in `App.swift` rather than `main.swift` deliberately: `@main`
/// cannot coexist with top-level code, and top-level code is not main-actor isolated, which
/// makes constructing the main-actor types below a compile error.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var store: UsageStore?
    private var statusItemController: StatusItemController?

    static func main() {
        if CommandLine.arguments.contains("--dump") {
            runDump()
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // `LSUIElement` already puts a bundled app in `.accessory` before launch; this call
        // matters for the unbundled `swift run` path, which starts `.prohibited` and would
        // otherwise show no status item at all.
        application.setActivationPolicy(.accessory)
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = UsageStore()
        self.store = store
        statusItemController = StatusItemController(store: store)
        store.start()
    }

    // MARK: - Headless mode

    /// Exercises the Keychain read, the network call and the parsing without touching
    /// AppKit, so the data pipeline can be checked from a terminal.
    private static func runDump() -> Never {
        // `Task.detached` rather than `Task`: this is a main-actor context, so an inheriting
        // task would need the main actor that `dispatchMain()` is about to park.
        Task.detached {
            do {
                let snapshot = try await UsageAPI.fetch()

                for limit in [snapshot.session, snapshot.weeklyAll].compactMap({ $0 }) {
                    let name = limit.id == "session" ? "Session (5h)" : "Week (all models)"
                    let reset = limit.resetsAt.map {
                        " · resets \(Format.resetPhrase($0)) (\(Format.relative(to: $0)))"
                    } ?? ""
                    let active = limit.isActive ? " · active" : ""
                    print("\(name): \(Format.percent(limit.percent))\(reset)\(active)")
                }

                for limit in snapshot.weeklyScoped {
                    print("Week (\(limit.label)): \(Format.percent(limit.percent))")
                }

                if snapshot.isEmpty {
                    print("No limits reported for this account.")
                }

                let barText: String
                if let session = snapshot.session {
                    let clock = session.resetsAt.map { " · " + Format.clock($0) } ?? ""
                    barText = Format.percent(session.percent) + clock
                } else {
                    barText = "—"
                }
                print("Menu bar would read: \(barText)")

                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }

        // Parks the main thread and services the main queue while the task above runs; the
        // task exits the process itself.
        dispatchMain()
    }
}
