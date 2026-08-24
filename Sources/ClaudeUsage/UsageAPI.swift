import Foundation

enum UsageError: LocalizedError, Equatable {
    case noCredentials(String)
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case httpStatus(Int)
    case transport(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .noCredentials(let detail):
            return detail
        case .unauthorized:
            return "Sign-in expired. Open Claude Code to refresh it."
        case .rateLimited:
            return "Rate limited by the usage API."
        case .httpStatus(let code):
            return "Anthropic API returned HTTP \(code)."
        case .transport(let detail):
            return detail
        case .decoding(let detail):
            return "Unexpected response format. \(detail)"
        }
    }

    /// Whether retrying on the next poll could plausibly succeed without the user acting.
    var isTransient: Bool {
        switch self {
        case .transport, .httpStatus, .rateLimited: return true
        case .noCredentials, .unauthorized, .decoding: return false
        }
    }
}

/// Reads the rolling rate-limit windows from the same endpoint Claude Code's own `/usage`
/// screen uses. Strictly read-only: this app never writes credentials and never attempts to
/// refresh the OAuth token itself — that remains Claude Code's job.
enum UsageAPI {

    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    static func fetch() async throws -> UsageSnapshot {
        let token: String
        do {
            token = try KeychainToken.read()
        } catch let error as KeychainError {
            throw UsageError.noCredentials(error.userFacingDescription)
        }

        do {
            return try await request(token: token)
        } catch UsageError.unauthorized {
            // Claude Code rotates the access token in place. If it has done so since we read
            // the Keychain a moment ago, a single retry with the fresh value recovers
            // silently; if the token is unchanged, it is genuinely expired.
            let refreshed = try? KeychainToken.read()
            guard let refreshed, refreshed != token else { throw UsageError.unauthorized }
            return try await request(token: refreshed)
        }
    }

    private static func request(token: String) async throws -> UsageSnapshot {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageError.transport((error as NSError).localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageError.transport("No HTTP response.")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw UsageError.unauthorized
        }
        if http.statusCode == 429 {
            // This endpoint sends `retry-after: 0`, which would mean "retry immediately" and
            // is worse than useless, so only a positive value is passed on; the caller backs
            // off on its own otherwise.
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            throw UsageError.rateLimited(retryAfter: retryAfter.map { $0 > 0 ? $0 : nil } ?? nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UsageError.httpStatus(http.statusCode)
        }

        do {
            let decoded = try decoder.decode(UsageResponse.self, from: data)
            return UsageSnapshot.from(decoded, now: Date())
        } catch {
            throw UsageError.decoding(error.localizedDescription)
        }
    }
}
