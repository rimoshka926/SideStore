import Foundation

// MARK: - Action types

/// The action decided by the scheduler.
public enum SchedulerAction: Equatable {
    /// Poll the local cert expiry — zero Apple API calls.
    case check
    /// Authenticate with Apple and re-sign — only when `days_left < threshold`.
    case resign
    /// Skip this cycle entirely.
    case skip(SkipReason)

    public enum SkipReason: String, Equatable, Sendable {
        /// Operator issued `/pause` via the Telegram bot.
        case paused
        /// Too many consecutive auth failures; circuit breaker is open.
        case breakerOpen
        /// No certificate expiry data available yet.
        case noCertData
    }
}

// MARK: - VIOSLSchedulerState

/// Pure, injectable scheduler decision engine.
///
/// "check ≠ auth": when `days_left >= resignThresholdDays`, the scheduler returns
/// `.check` — zero Apple API calls occur. This is the core invariant that protects
/// the burner Apple ID from excessive logins.
///
/// Calling `decide()` is **read-only** — it never mutates the circuit breaker.
/// The caller must call `breaker.recordSuccess()` / `breaker.recordFailure()` after
/// executing the action.
public struct VIOSLSchedulerState {

    public let resignThresholdDays: Double
    public let breaker: VIOSLCircuitBreaker

    public init(
        resignThresholdDays: Double = 3.0,
        breaker: VIOSLCircuitBreaker = VIOSLCircuitBreaker()
    ) {
        self.resignThresholdDays = resignThresholdDays
        self.breaker = breaker
    }

    // MARK: - Decision

    /// Decides the next scheduler action.
    ///
    /// - Parameters:
    ///   - daysLeft: Days remaining on the current certificate. `nil` if no cert data.
    ///   - paused: Whether the backend `/pause` flag is active.
    ///   - now: Current timestamp; injectable for deterministic tests.
    /// - Returns: The action to execute this cycle.
    public func decide(daysLeft: Double?, paused: Bool, now: Date = Date()) -> SchedulerAction {
        guard let days = daysLeft else {
            return .skip(.noCertData)
        }

        if paused {
            return .skip(.paused)
        }

        if days >= resignThresholdDays {
            return .check
        }

        // days_left < threshold → re-sign is needed; peek at breaker (read-only)
        guard breaker.peekCanAttempt(now: now) else {
            return .skip(.breakerOpen)
        }

        return .resign
    }
}
