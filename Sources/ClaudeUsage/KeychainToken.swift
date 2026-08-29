import Foundation

enum KeychainError: LocalizedError {
    case itemNotFound
    case toolFailed(status: Int32, message: String)
    case timedOut
    case malformedPayload

    var errorDescription: String? { userFacingDescription }

    var userFacingDescription: String {
        switch self {
        case .itemNotFound:
            return "No Claude Code credentials found. Sign in with Claude Code first."
        case .toolFailed(let status, let message):
            let detail = message.isEmpty ? "" : " \(message)"
            return "Could not read the Keychain (exit \(status)).\(detail)"
        case .timedOut:
            return "Timed out reading the Keychain."
        case .malformedPayload:
            return "Claude Code credentials are in an unexpected format."
        }
    }
}

/// Reads the OAuth access token Claude Code stores in the login Keychain.
///
/// This deliberately shells out to `/usr/bin/security` rather than calling
/// `SecItemCopyMatching` directly. The Keychain item's ACL grants read access
/// (`ACLAuthorizationDecrypt`) to exactly one trusted application — `/usr/bin/security` —
/// because that is what Claude Code writes it with. A direct API read from this app is not
/// on that list, and rather than failing cleanly it spawns a **blocking** SecurityAgent
/// prompt that hangs the calling thread indefinitely. Suppressing that prompt requires the
/// deprecated, process-global `SecKeychainSetUserInteractionAllowed(false)`, and even then
/// the read only returns `errSecAuthFailed`. Granting access via "Always Allow" would not
/// survive a rebuild either, since an ad-hoc signature's designated requirement is pinned to
/// a cdhash that changes on every compile.
///
/// `/usr/bin/security` has a stable Apple code identity, so it stays trusted permanently and
/// reads the item silently, with no prompt. Access is strictly read-only: this app never
/// writes credentials and never refreshes the token.
enum KeychainToken {

    static let service = "Claude Code-credentials"

    /// `security` exits with this when no matching item exists.
    private static let notFoundExitCode: Int32 = 44

    /// The access token plus its stated expiry. `expiresAt` is a timestamp, not a secret.
    struct Credential {
        let token: String
        let expiresAt: Date?

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt <= Date()
        }
    }

    static func read() throws -> String {
        try readCredential().token
    }

    static func readCredential() throws -> Credential {
        let payload = try runSecurityTool()

        // The item's account is the macOS username rather than a fixed value, and only one
        // item exists per service, so matching on the service name alone is unambiguous.
        guard let blob = try? JSONDecoder().decode(CredentialBlob.self, from: payload),
              let token = blob.claudeAiOauth?.accessToken,
              !token.isEmpty
        else {
            throw KeychainError.malformedPayload
        }
        // Claude Code writes milliseconds; tolerate seconds in case that ever changes.
        let expiry = blob.claudeAiOauth?.expiresAt.map { raw -> Date in
            Date(timeIntervalSince1970: raw > 1_000_000_000_000 ? raw / 1000 : raw)
        }
        return Credential(token: token, expiresAt: expiry)
    }

    private struct CredentialBlob: Decodable {
        let claudeAiOauth: OAuth?

        struct OAuth: Decodable {
            let accessToken: String?
            /// A timestamp, not a secret — used to skip a request that is certain to 401.
            let expiresAt: Double?
            // refreshToken / expiresAt / scopes / subscriptionType / rateLimitTier are
            // present but intentionally not decoded — this app only ever needs the token.
        }
    }

    private static func runSecurityTool(timeout: TimeInterval = 8) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]

        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw KeychainError.toolFailed(status: -1, message: error.localizedDescription)
        }

        // Watchdog: `security` should return in milliseconds, but a wedged subprocess must
        // never hang the refresh loop.
        var timedOut = false
        let watchdog = DispatchWorkItem {
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        // Reads finish when the child closes its pipes; the payload is well under the pipe
        // buffer, so draining stdout before stderr cannot deadlock here.
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        if timedOut { throw KeychainError.timedOut }

        guard process.terminationStatus == 0 else {
            if process.terminationStatus == notFoundExitCode {
                throw KeychainError.itemNotFound
            }
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw KeychainError.toolFailed(status: process.terminationStatus, message: message)
        }

        // `-w` appends a trailing newline that would otherwise break JSON parsing.
        guard let text = String(data: outputData, encoding: .utf8) else {
            throw KeychainError.malformedPayload
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            throw KeychainError.malformedPayload
        }
        return data
    }
}
