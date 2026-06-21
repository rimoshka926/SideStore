import XCTest
@testable import VIOSLCore

// MARK: - TelemetryReportTests

/// Verifies that TelemetryReport encodes/decodes correctly to the Stage 3 backend contract.
///
/// Tests are pure: no network, no UIKit. Date strategy is injected per-test to ensure
/// RFC 3339 / ISO 8601 UTC format expected by the Rust backend.
final class TelemetryReportTests: XCTestCase {

    // MARK: - Fixtures

    private var encoder: JSONEncoder!
    private var decoder: JSONDecoder!

    /// A fixed epoch so tests don't depend on wall-clock time.
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z

    override func setUp() {
        super.setUp()
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - JSON key names

    func testCodingKeysAreSnakeCase() throws {
        let report = makeReport()
        let json = try encodeToDict(report)

        XCTAssertNotNil(json["bundle_id"],  "Missing 'bundle_id'")
        XCTAssertNotNil(json["cert_expiry"], "Missing 'cert_expiry'")
        XCTAssertNotNil(json["signed_at"],  "Missing 'signed_at'")
        XCTAssertNotNil(json["ok"],         "Missing 'ok'")
    }

    func testNoCamelCaseKeysLeakIntoJSON() throws {
        let report = makeReport()
        let json = try encodeToDict(report)

        XCTAssertNil(json["bundleId"],   "camelCase 'bundleId' must not appear in JSON")
        XCTAssertNil(json["certExpiry"], "camelCase 'certExpiry' must not appear in JSON")
        XCTAssertNil(json["signedAt"],   "camelCase 'signedAt' must not appear in JSON")
    }

    // MARK: - Field values

    func testBundleIdRoundTrips() throws {
        let report = makeReport(bundleId: "io.viosl.SideStore")
        let decoded = try roundTrip(report)
        XCTAssertEqual(decoded.bundleId, "io.viosl.SideStore")
    }

    func testOkTrueRoundTrips() throws {
        let report = makeReport(ok: true)
        let decoded = try roundTrip(report)
        XCTAssertTrue(decoded.ok)
    }

    func testOkFalseRoundTrips() throws {
        let report = makeReport(ok: false)
        let decoded = try roundTrip(report)
        XCTAssertFalse(decoded.ok)
    }

    func testCertExpiryRoundTripsWithinOneSecond() throws {
        let expiry = epoch.addingTimeInterval(7 * 24 * 3600) // +7 days
        let report = makeReport(certExpiry: expiry)
        let decoded = try roundTrip(report)
        // ISO8601 truncates sub-second precision → allow 1-second tolerance
        XCTAssertEqual(decoded.certExpiry.timeIntervalSince1970,
                       expiry.timeIntervalSince1970,
                       accuracy: 1.0)
    }

    func testSignedAtRoundTripsWithinOneSecond() throws {
        let report = makeReport(signedAt: epoch)
        let decoded = try roundTrip(report)
        XCTAssertEqual(decoded.signedAt.timeIntervalSince1970,
                       epoch.timeIntervalSince1970,
                       accuracy: 1.0)
    }

    // MARK: - Decode from raw JSON string (as backend would receive)

    func testDecodeFromRawBackendJSON() throws {
        let rawJSON = """
        {
            "bundle_id":   "io.viosl.SideStore",
            "cert_expiry": "2023-11-21T22:13:20Z",
            "signed_at":   "2023-11-14T22:13:20Z",
            "ok":          true
        }
        """
        let data = rawJSON.data(using: .utf8)!
        let report = try decoder.decode(TelemetryReport.self, from: data)
        XCTAssertEqual(report.bundleId, "io.viosl.SideStore")
        XCTAssertTrue(report.ok)
    }

    func testEqualityReflectsAllFields() throws {
        let a = makeReport(ok: true)
        let b = makeReport(ok: false)
        let c = makeReport(ok: true)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, c)
    }

    // MARK: - Helpers

    private func makeReport(
        bundleId: String = "io.viosl.SideStore",
        certExpiry: Date? = nil,
        signedAt: Date? = nil,
        ok: Bool = true
    ) -> TelemetryReport {
        TelemetryReport(
            bundleId: bundleId,
            certExpiry: certExpiry ?? epoch.addingTimeInterval(7 * 24 * 3600),
            signedAt: signedAt ?? epoch,
            ok: ok
        )
    }

    private func roundTrip(_ report: TelemetryReport) throws -> TelemetryReport {
        let data = try encoder.encode(report)
        return try decoder.decode(TelemetryReport.self, from: data)
    }

    private func encodeToDict(_ report: TelemetryReport) throws -> [String: Any] {
        let data = try encoder.encode(report)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }
}
