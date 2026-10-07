import Foundation

/// Gets an expired OAuth token renewed by briefly running Claude Code in the background.
///
/// The app still never touches the refresh token or writes to the Keychain. Claude Code
/// renews its own credentials as part of starting up, before it has been asked anything, so
/// launching it headless with stdin held open and no message ever sent is enough: the token
/// rotates within a couple of seconds, no prompt reaches the model, and no quota is spent.
/// Once the Keychain shows the new token the process is terminated.
///
/// `claude auth status` is not a substitute — it reports the sign-in without renewing it —
/// and `--bare` cannot be used because it skips Keychain auth altogether.
enum TokenRefresher {

    /// Floor between launches. Scheduled retries are already spaced further apart than this
    /// by the failure backoff; this stops the refresh button from spawning a process per
    /// click when the sign-in is beyond what Claude Code can renew on its own.
    static let minimumInterval: TimeInterval = 120
    /// The rotation normally lands in under two seconds; a slow network gets some slack.
    private static let timeout: TimeInterval = 20
    private static let pollInterval: TimeInterval = 0.5

    private static let lock = NSLock()
    private static var lastAttemptAt: Date?

    /// Returns the renewed credential, or `nil` if Claude Code is not installed, was launched
    /// too recently, or did not rotate the token in time.
    static func renew(replacing stale: KeychainToken.Credential) async -> KeychainToken.Credential? {
        guard let executable = locateClaude(), claimAttempt() else { return nil }

        let process = Process()
        process.executableURL = executable
        // Stream-JSON input is what makes it wait on stdin instead of exiting for want of a
        // prompt. The last two flags keep the launch inert: none of the user's MCP servers
        // are started and no session transcript is left behind.
        process.arguments = ["-p",
                             "--input-format", "stream-json",
                             "--output-format", "stream-json",
                             "--verbose",
                             "--strict-mcp-config",
                             "--no-session-persistence"]
        // A neutral directory, so no project's CLAUDE.md or settings are picked up.
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            if let fresh = try? KeychainToken.readCredential(),
               fresh.token != stale.token, !fresh.isExpired {
                return fresh
            }
            // It exited without rotating anything; waiting longer cannot help.
            if !process.isRunning { break }
        }
        return nil
    }

    private static func claimAttempt() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if let last = lastAttemptAt, now.timeIntervalSince(last) < minimumInterval { return false }
        lastAttemptAt = now
        return true
    }

    /// A menu bar app does not inherit the shell's PATH, so the usual install locations are
    /// checked directly.
    private static func locateClaude() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude",
                          "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude"]
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}
