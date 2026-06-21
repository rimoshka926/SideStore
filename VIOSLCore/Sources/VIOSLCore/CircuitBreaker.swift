import Foundation

// MARK: - State

public enum CircuitBreakerState: Equatable {
    case closed
    case open(until: Date)
    case halfOpen
}

// MARK: - VIOSLCircuitBreaker

/// Exponential-backoff circuit breaker protecting Apple-auth operations.
///
/// States:
///   closed   → normal, allows all attempts
///   open     → too many consecutive failures; blocks until cooldown expires
///   halfOpen → cooldown expired; allows one probe attempt
///
/// Not thread-safe: callers must synchronize externally (e.g. on a serial queue).
public final class VIOSLCircuitBreaker {

    public struct Config {
        /// Maximum consecutive failures before opening the breaker.
        public var maxConsecutiveFailures: Int
        /// Initial cooldown after the first trip (seconds).
        public var baseCooldown: TimeInterval
        /// Maximum cooldown cap (seconds).
        public var maxCooldown: TimeInterval
        /// Each subsequent trip multiplies the cooldown by this factor.
        public var cooldownMultiplier: Double

        public init(
            maxConsecutiveFailures: Int = 3,
            baseCooldown: TimeInterval = 3600,
            maxCooldown: TimeInterval = 86400,
            cooldownMultiplier: Double = 2.0
        ) {
            self.maxConsecutiveFailures = maxConsecutiveFailures
            self.baseCooldown = baseCooldown
            self.maxCooldown = maxCooldown
            self.cooldownMultiplier = cooldownMultiplier
        }
    }

    public let config: Config

    /// Number of consecutive failures since the last success.
    public private(set) var consecutiveFailures: Int = 0
    /// Total number of times the breaker has opened.
    public private(set) var totalTrips: Int = 0
    /// Current breaker state.
    public private(set) var state: CircuitBreakerState = .closed

    public init(config: Config = Config()) {
        self.config = config
    }

    // MARK: - API

    /// Read-only check: returns `true` if an attempt is currently allowed.
    /// Does **not** modify state. Use in `decide()` for read-only queries.
    public func peekCanAttempt(now: Date = Date()) -> Bool {
        switch state {
        case .closed: return true
        case .open(let until): return now >= until
        case .halfOpen: return true
        }
    }

    /// Stateful check: returns `true` if an attempt is allowed.
    /// Transitions `.open → .halfOpen` when cooldown expires.
    /// Call this when actually about to execute the operation (e.g. in RefreshGate).
    @discardableResult
    public func canAttempt(now: Date = Date()) -> Bool {
        switch state {
        case .closed:
            return true
        case .open(let until):
            guard now >= until else { return false }
            state = .halfOpen
            return true
        case .halfOpen:
            return true
        }
    }

    /// Records a successful attempt. Resets failure count and closes the breaker.
    public func recordSuccess() {
        consecutiveFailures = 0
        state = .closed
    }

    /// Records a failed attempt. Opens the breaker after `maxConsecutiveFailures`.
    public func recordFailure(now: Date = Date()) {
        consecutiveFailures += 1
        if consecutiveFailures >= config.maxConsecutiveFailures {
            totalTrips += 1
            let exponent = Double(totalTrips - 1)
            let rawCooldown = config.baseCooldown * pow(config.cooldownMultiplier, exponent)
            let cooldown = min(rawCooldown, config.maxCooldown)
            state = .open(until: now.addingTimeInterval(cooldown))
        }
    }
}
