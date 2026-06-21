import Foundation
import os.log

// MARK: - Action types

enum VIOSLSchedulerAction: Equatable {
    /// Poll local cert expiry — zero Apple API calls.
    case check
    /// Authenticate with Apple and re-sign — only when days_left < threshold.
    case resign
    /// Skip this cycle.
    case skip(VIOSLSkipReason)
}

enum VIOSLSkipReason: String, Equatable {
    case paused         // operator issued /pause via Telegram bot
    case breakerOpen    // circuit breaker is open after consecutive auth failures
    case noCertData     // no cert expiry data available yet
}

// MARK: - VIOSLScheduler

/// Decides whether to CHECK (poll, no Apple) or RE-SIGN (auth + re-sign).
///
/// "check ≠ auth": when days_left >= resignThresholdDays the scheduler returns
/// `.check` — zero Apple API calls occur. This is the core invariant protecting
/// the burner Apple ID from excessive logins and rate-limiting.
///
/// Calling `decide()` is READ-ONLY. After executing the action call
/// `breaker.recordSuccess()` or `breaker.recordFailure()` accordingly.
///
/// Pure logic is mirrored in VIOSLCore/Sources/VIOSLCore/Scheduler.swift for XCTest coverage.
final class VIOSLScheduler {

    static let shared = VIOSLScheduler()

    let resignThresholdDays: Double = 3.0
    let breaker: VIOSLCircuitBreaker

    private let log = Logger(subsystem: "io.viosl.SideStore", category: "Scheduler")

    init(breaker: VIOSLCircuitBreaker = VIOSLCircuitBreaker()) {
        self.breaker = breaker
    }

    // MARK: - Decision

    /// Decides the next action for this scheduler cycle.
    ///
    /// - Parameters:
    ///   - daysLeft: Days remaining on current certificate. `nil` when no cert data exists.
    ///   - paused: Whether the backend `/pause` flag is active (set via Telegram `/pause`).
    ///   - now: Current timestamp. Defaulting to `Date()` in production; inject in tests.
    func decide(daysLeft: Double?, paused: Bool, now: Date = Date()) -> VIOSLSchedulerAction {
        guard let days = daysLeft else {
            log.debug("Scheduler → skip(noCertData): no cert expiry data")
            return .skip(.noCertData)
        }

        if paused {
            log.info("Scheduler → skip(paused): operator pause active")
            return .skip(.paused)
        }

        if days >= resignThresholdDays {
            log.info("Scheduler → check: days_left=\(days, privacy: .public) >= threshold=\(self.resignThresholdDays, privacy: .public)")
            return .check
        }

        guard breaker.peekCanAttempt(now: now) else {
            log.warning("Scheduler → skip(breakerOpen): circuit breaker is open")
            return .skip(.breakerOpen)
        }

        log.notice("Scheduler → resign: days_left=\(days, privacy: .public) < threshold=\(self.resignThresholdDays, privacy: .public)")
        return .resign
    }
}

// MARK: - VIOSLRefreshGate

/// Entry point called by AppDelegate, BGTask, and Shortcuts.
/// Evaluates the scheduler decision and executes the appropriate action.
///
/// Stage 7: decision + logging only. Re-sign execution wired in Stage 10.
final class VIOSLRefreshGate {

    static let shared = VIOSLRefreshGate()

    private let scheduler: VIOSLScheduler
    private let log = Logger(subsystem: "io.viosl.SideStore", category: "RefreshGate")

    init(scheduler: VIOSLScheduler = .shared) {
        self.scheduler = scheduler
    }

    /// Evaluates whether a re-sign is needed, logs the decision, and fires telemetry.
    ///
    /// - Parameters:
    ///   - daysLeft: From the most recent cert info stored by SideStore.
    ///   - certExpiry: Current certificate expiry date; `nil` when not yet known.
    ///                 When provided, a telemetry CHECK report is sent on `.check` action.
    ///   - paused: From the last successful `/state` poll (defaults to `false` if backend unreachable).
    /// - Returns: The decided action. Caller may use this to drive UI or BGTask completion.
    @discardableResult
    func evaluate(daysLeft: Double?, certExpiry: Date? = nil, paused: Bool) -> VIOSLSchedulerAction {
        let action = scheduler.decide(daysLeft: daysLeft, paused: paused)
        switch action {
        case .check:
            log.info("RefreshGate: CHECK — cert healthy, no re-sign needed")
            if let expiry = certExpiry {
                // Report CHECK health to backend. Fire-and-forget; network failure queues the report.
                Task {
                    await VIOSLTelemetryClient.shared.send(
                        certExpiry: expiry,
                        signedAt: Date(),
                        ok: true
                    )
                }
            }
        case .resign:
            log.notice("RefreshGate: RESIGN — cert expiry within threshold, triggering re-sign")
            // Stateful breaker check: may transition open→halfOpen at this point.
            guard scheduler.breaker.canAttempt() else {
                log.warning("RefreshGate: breaker blocked attempt after decide (race); skipping")
                return .skip(.breakerOpen)
            }
            // TODO Stage 10: invoke SideStore refresh operation here, then:
            //   On success: breaker.recordSuccess()
            //               Task { await VIOSLTelemetryClient.shared.send(certExpiry: newExpiry,
            //                                                              signedAt: Date(), ok: true) }
            //   On failure: breaker.recordFailure()
            //               Task { await VIOSLTelemetryClient.shared.send(certExpiry: lastKnownExpiry,
            //                                                              signedAt: Date(), ok: false) }
        case .skip(let reason):
            log.info("RefreshGate: SKIP (\(reason.rawValue, privacy: .public))")
        }
        return action
    }
}
