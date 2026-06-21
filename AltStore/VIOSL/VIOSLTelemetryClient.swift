import Foundation
import os.log

// MARK: - VIOSLTelemetryClient

/// Non-blocking HTTP client that reports cert/resign events to the VIOSL backend.
///
/// Thread-safety: implemented as a Swift `actor` — all state mutations are serialized.
///
/// Usage (fire-and-forget):
///   Task { await VIOSLTelemetryClient.shared.send(certExpiry: ..., signedAt: ..., ok: true) }
///
/// Offline behaviour:
///   On network failure the report is persisted to UserDefaults (max 10 entries).
///   Call `drainQueue()` on app launch (Stage 10: wire into AppDelegate) to retry pending reports.
///   On HTTP 401 the report is discarded — bad secret must be fixed in xcconfig, not retried.
actor VIOSLTelemetryClient {

    static let shared = VIOSLTelemetryClient()

    // MARK: - Private state

    private let session: URLSession
    private let log = Logger(subsystem: "io.viosl.SideStore", category: "Telemetry")
    private let isoFormatter: ISO8601DateFormatter

    /// UserDefaults key storing JSON-encoded [PendingReport].
    private let queueKey = "viosl.telemetry.pending"
    private let maxQueueSize = 10

    // MARK: - Init

    init(session: URLSession = .shared) {
        self.session = session
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]   // produces "2024-01-15T12:00:00Z"
        self.isoFormatter = fmt
    }

    // MARK: - Public API

    /// Reports a cert-check or re-sign event to the backend.
    ///
    /// - Parameters:
    ///   - certExpiry: Current certificate expiry date.
    ///   - signedAt: Timestamp of the check/resign action (pass `Date()` for now).
    ///   - ok: `true` for CHECK or successful resign; `false` for failed resign.
    func send(certExpiry: Date, signedAt: Date, ok: Bool) async {
        let body = PendingReport(
            bundle_id: "io.viosl.SideStore",
            cert_expiry: isoFormatter.string(from: certExpiry),
            signed_at: isoFormatter.string(from: signedAt),
            ok: ok
        )
        log.debug("Telemetry: sending report ok=\(ok) certExpiry=\(body.cert_expiry, privacy: .public)")
        let accepted = await post(body: body)
        if !accepted {
            enqueue(body)
            log.warning("Telemetry: queued report (pending: \(self.pendingReports().count))")
        }
    }

    /// Retries all pending (previously failed) reports. Call on app launch.
    ///
    /// Stage 10 wire-up:
    ///   In `AppDelegate.application(_:didFinishLaunchingWithOptions:)` add:
    ///   `Task { await VIOSLTelemetryClient.shared.drainQueue() }`
    func drainQueue() async {
        let pending = pendingReports()
        guard !pending.isEmpty else { return }
        log.info("Telemetry: draining \(pending.count) pending report(s)")
        var remaining: [PendingReport] = []
        for body in pending {
            let accepted = await post(body: body)
            if !accepted {
                remaining.append(body)
            }
        }
        savePending(remaining)
        if remaining.isEmpty {
            log.info("Telemetry: offline queue cleared")
        } else {
            log.warning("Telemetry: \(remaining.count) report(s) still pending after drain")
        }
    }

    // MARK: - Private

    /// Encodable struct mirroring the Stage 3 backend POST /report contract.
    private struct PendingReport: Codable {
        let bundle_id: String
        let cert_expiry: String   // ISO8601 UTC string
        let signed_at: String     // ISO8601 UTC string
        let ok: Bool
    }

    /// POSTs a report to the backend.
    /// Returns `true` on HTTP 200/201 (accepted).
    /// Returns `false` on network error or unexpected status (retriable).
    /// Returns `false` on HTTP 401 after logging the config error (permanent failure, not retriable).
    @discardableResult
    private func post(body: PendingReport) async -> Bool {
        let endpoint = VIOSLConfig.telemetryURL.appendingPathComponent("report")
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(VIOSLConfig.backendSecret)",
                         forHTTPHeaderField: "Authorization")
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            log.error("Telemetry: failed to encode report body: \(error.localizedDescription, privacy: .public)")
            return false
        }
        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200, 201:
                log.info("Telemetry: accepted (HTTP \(status))")
                return true
            case 401:
                // Permanent failure — wrong BACKEND_SECRET; don't enqueue to avoid filling queue.
                log.error("Telemetry: HTTP 401 — BACKEND_SECRET mismatch; fix xcconfig or CI secret")
                return false
            default:
                log.warning("Telemetry: HTTP \(status) — will retry")
                return false
            }
        } catch {
            log.warning("Telemetry: network error — \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Queue persistence (UserDefaults)

    private func pendingReports() -> [PendingReport] {
        guard let data = UserDefaults.standard.data(forKey: queueKey),
              let list = try? JSONDecoder().decode([PendingReport].self, from: data)
        else { return [] }
        return list
    }

    private func enqueue(_ body: PendingReport) {
        var list = pendingReports()
        list.append(body)
        if list.count > maxQueueSize {
            // Drop oldest entries to stay within the cap.
            list = Array(list.suffix(maxQueueSize))
        }
        savePending(list)
    }

    private func savePending(_ list: [PendingReport]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: queueKey)
    }
}
