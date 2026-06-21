import Foundation

// MARK: - TelemetryReport

/// Pure data model for VIOSL backend POST /report payload.
///
/// JSON field names follow the snake_case contract defined in Stage 3 (Rust backend).
/// Encoding/decoding dates is the caller's responsibility via encoder.dateEncodingStrategy.
///
/// API contract (Stage 3):
///   POST /report
///   Authorization: Bearer <secret>
///   Content-Type: application/json
///   { "bundle_id": "...", "cert_expiry": "RFC3339", "signed_at": "RFC3339", "ok": true }
///   → 201 {"accepted": true}
public struct TelemetryReport: Codable, Equatable, Sendable {

    /// App bundle identifier being reported (e.g. "io.viosl.SideStore").
    public let bundleId: String
    /// Certificate expiry date (UTC).
    public let certExpiry: Date
    /// Timestamp of the sign/check action (UTC).
    public let signedAt: Date
    /// `true` when re-sign succeeded or cert is healthy; `false` on resign failure.
    public let ok: Bool

    public init(bundleId: String, certExpiry: Date, signedAt: Date, ok: Bool) {
        self.bundleId = bundleId
        self.certExpiry = certExpiry
        self.signedAt = signedAt
        self.ok = ok
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case bundleId  = "bundle_id"
        case certExpiry = "cert_expiry"
        case signedAt   = "signed_at"
        case ok
    }
}
