import Foundation
import ServiceManagement

enum LoginItemError: LocalizedError {
    case notBundled
    case needsApproval
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notBundled:
            return "Launch at login needs the built app bundle (run dist/ClaudeUsage.app)."
        case .needsApproval:
            return "Enable Claude Usage in System Settings › General › Login Items."
        case .failed(let detail):
            return detail
        }
    }
}

/// Wraps `SMAppService.mainApp`, which is keyed on `CFBundleIdentifier`.
enum LoginItem {

    /// `register()` does **not** throw when the process is a bare SwiftPM binary — it
    /// silently registers the binary's parent directory (`.build/.../release`) as a login
    /// item. Guarding on a real `.app` bundle is what prevents that.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    /// An app that has never been registered reports `.notFound`, not `.notRegistered`, so
    /// this must test for `.enabled` rather than for the absence of some other state.
    /// (`.notFound` also appears when the bundle's signature is invalid.)
    static var isEnabled: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    static var requiresApproval: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        guard isAvailable else { throw LoginItemError.notBundled }

        do {
            if enabled {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    throw LoginItemError.needsApproval
                }
            } else if SMAppService.mainApp.status != .notRegistered {
                // Unregistering something already unregistered throws; skip the no-op.
                try SMAppService.mainApp.unregister()
            }
        } catch let error as LoginItemError {
            throw error
        } catch {
            throw LoginItemError.failed(error.localizedDescription)
        }
    }
}
