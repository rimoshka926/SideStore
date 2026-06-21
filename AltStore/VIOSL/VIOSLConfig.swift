import Foundation

/// Reads VIOSL configuration injected via Info.plist at build time.
/// Values come from VIOSL.xcconfig (gitignored) or CI-injected xcconfig.
/// Fallbacks are localhost addresses safe for development.
enum VIOSLConfig {

    /// Self-hosted anisette server URL. Used by the SideStore refresh operation.
    static let anisetteURL: URL = resolveURL(
        key: "VIOSLAnisetteURL",
        fallback: "http://localhost:6969/"
    )

    /// VIOSL backend URL. Receives POST /report after re-sign.
    static let telemetryURL: URL = resolveURL(
        key: "VIOSLTelemetryURL",
        fallback: "http://localhost:8080/"
    )

    /// Auth header value for POST /report.
    static let backendSecret: String = {
        (Bundle.main.object(forInfoDictionaryKey: "VIOSLBackendSecret") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "dev-placeholder"
    }()

    // MARK: - Private

    private static func resolveURL(key: String, fallback: String) -> URL {
        let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? fallback
        return URL(string: raw) ?? URL(string: fallback)!
    }
}
