import Foundation
import os.log

// MARK: - State

enum VIOSLCircuitBreakerState: Equatable {
    case closed
    case open(until: Date)
    case halfOpen
}

// MARK: - VIOSLCircuitBreaker

/// Exponential-backoff circuit breaker protecting Apple-auth operations.
///
/// States:
///   closed   → normal; allows all attempts
///   open     → too many consecutive failures; blocks until cooldown expires
///   halfOpen → cooldown expired; allows one probe attempt
///
/// Not thread-safe: callers synchronize on AppDelegate's main queue or a dedicated serial queue.
/// Pure logic is mirrored in VIOSLCore/Sources/VIOSLCore/CircuitBreaker.swift for XCTest coverage.
final class VIOSLCircuitBreaker {

    struct Config {
        var maxConsecutiveFailures: Int = 3
        var baseCooldown: TimeInterval = 3600
        var maxCooldown: TimeInterval = 86400
        var cooldownMultiplier: Double = 2.0
    }

    private let config: Config
    private let log = Logger(subsystem: "io.viosl.SideStore", category: "CircuitBreaker")

    private(set) var consecutiveFailures: Int = 0
    private(set) var totalTrips: Int = 0
    private(set) var state: VIOSLCircuitBreakerState = .closed

    init(config: Config = Config()) {
        self.config = config
    }

    // MARK: - API

    /// Read-only check: `true` if an attempt would be allowed. Does not modify state.
    /// Used by Scheduler.decide() for pure, side-effect-free decision logic.
    func peekCanAttempt(now: Date = Date()) -> Bool {
        switch state {
        case .closed: return true
        case .open(let until): return now >= until
        case .halfOpen: return true
        }
    }

    /// Stateful check: `true` if an attempt is allowed.
    /// Transitions `.open → .halfOpen` when cooldown expires.
    /// Call this when actually about to execute the resign operation (in VIOSLRefreshGate).
    @discardableResult
    func canAttempt(now: Date = Date()) -> Bool {
        switch state {
        case .closed:
            return true
        case .open(let until):
            guard now >= until else { return false }
            state = .halfOpen
            log.info("CircuitBreaker → halfOpen after cooldown")
            return true
        case .halfOpen:
            return true
        }
    }

    /// Records a successful attempt. Resets failure count and closes the breaker.
    func recordSuccess() {
        consecutiveFailures = 0
        state = .closed
        log.info("CircuitBreaker → closed (success)")
    }

    /// Records a failed attempt. Opens the breaker after maxConsecutiveFailures.
    func recordFailure(now: Date = Date()) {
        consecutiveFailures += 1
        if consecutiveFailures >= config.maxConsecutiveFailures {
            totalTrips += 1
            let exponent = Double(totalTrips - 1)
            let rawCooldown = config.baseCooldown * pow(config.cooldownMultiplier, exponent)
            let cooldown = min(rawCooldown, config.maxCooldown)
            state = .open(until: now.addingTimeInterval(cooldown))
            log.error("CircuitBreaker → open (trip #\(self.totalTrips), cooldown \(cooldown, privacy: .public)s)")
        } else {
            log.warning("CircuitBreaker: failure \(self.consecutiveFailures)/\(self.config.maxConsecutiveFailures)")
        }
    }
}
