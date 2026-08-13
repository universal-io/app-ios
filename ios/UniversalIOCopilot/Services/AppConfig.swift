import Foundation

/// Where the app talks to and what it identifies itself with.
///
/// Both values come from the build, not from source: point a build at a local
/// server by setting them in `Local.xcconfig` (see ios/README.md). The beta
/// token is a build credential, not a user secret — it is replaced by Sign in
/// with Apple and StoreKit entitlements before launch.
enum AppConfig {
    static let apiBaseURL: URL = {
        let raw = infoValue("UIODefaultAPIBaseURL") ?? "http://localhost:3000"
        guard let url = URL(string: raw) else {
            preconditionFailure("UIODefaultAPIBaseURL is not a valid URL: \(raw)")
        }
        return url
    }()

    static let betaToken: String = infoValue("UIOBetaToken") ?? ""

    static var isConfigured: Bool { !betaToken.isEmpty }

    private static func infoValue(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
