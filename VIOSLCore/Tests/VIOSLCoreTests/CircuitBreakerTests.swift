import XCTest
@testable import VIOSLCore

final class CircuitBreakerTests: XCTestCase {

    // Frozen reference time for determinism
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - Initial state

    func testInitiallyAllowsAttempt() {
        let breaker = VIOSLCircuitBreaker()
        XCTAssertTrue(breaker.canAttempt(now: t0))
        XCTAssertEqual(breaker.state, .closed)
        XCTAssertEqual(breaker.consecutiveFailures, 0)
    }

    // MARK: - Failure accumulation

    func testSingleFailureDoesNotOpen() {
        let breaker = VIOSLCircuitBreaker(config: .init(maxConsecutiveFailures: 3))
        breaker.recordFailure(now: t0)
        XCTAssertEqual(breaker.consecutiveFailures, 1)
        XCTAssertTrue(breaker.canAttempt(now: t0), "One failure must not open the breaker")
    }

    func testOpenAfterMaxConsecutiveFailures() {
        let breaker = VIOSLCircuitBreaker(config: .init(maxConsecutiveFailures: 3, baseCooldown: 3600))
        breaker.recordFailure(now: t0)
        breaker.recordFailure(now: t0)
        XCTAssertTrue(breaker.canAttempt(now: t0), "2/3 failures: still closed")
        breaker.recordFailure(now: t0)
        XCTAssertFalse(breaker.canAttempt(now: t0), "3/3 failures: must be open")
        XCTAssertEqual(breaker.totalTrips, 1)
    }

    // MARK: - Open state blocks attempts during cooldown

    func testOpenBlocksDuringCooldown() {
        let cfg = VIOSLCircuitBreaker.Config(maxConsecutiveFailures: 2, baseCooldown: 100)
        let breaker = VIOSLCircuitBreaker(config: cfg)
        breaker.recordFailure(now: t0)
        breaker.recordFailure(now: t0)
        XCTAssertFalse(breaker.canAttempt(now: t0.addingTimeInterval(50)),
                       "Must block while 50 < 100s cooldown")
        XCTAssertFalse(breaker.canAttempt(now: t0.addingTimeInterval(99)),
                       "Must block at 99s (< 100s cooldown)")
    }

    // MARK: - peekCanAttempt (read-only, no state transition)

    func testPeekDoesNotTransitionOpenToHalfOpen() {
        let cfg = VIOSLCircuitBreaker.Config(maxConsecutiveFailures: 2, baseCooldown: 100)
        let breaker = VIOSLCircuitBreaker(config: cfg)
        breaker.recordFailure(now: t0)
        breaker.recordFailure(now: t0)
        // Peek at expiry — should return true but NOT transition state
        let result = breaker.peekCanAttempt(now: t0.addingTimeInterval(100))
        XCTAssertTrue(result, "peekCanAttempt must return true after cooldown expiry")
        if case .open(_) = breaker.state { /* still open — correct */ } else {
            XCTFail("peekCanAttempt must NOT transition to halfOpen; state: \(breaker.state)")
        }
    }

    func testPeekReturnsFalseWhileOpen() {
        let cfg = VIOSLCircuitBreaker.Config(maxConsecutiveFailures: 2, baseCooldown: 100)
        let breaker = VIOSLCircuitBreaker(config: cfg)
        breaker.recordFailure(now: t0)
        breaker.recordFailure(now: t0)
        XCTAssertFalse(breaker.peekCanAttempt(now: t0.addingTimeInterval(50)))
    }

    // MARK: - Transition to halfOpen after cooldown (canAttempt — stateful)

    func testTransitionsToHalfOpenAtCooldownExpiry() {
        let cfg = VIOSLCircuitBreaker.Config(maxConsecutiveFailures: 2, baseCooldown: 100)
        let breaker = VIOSLCircuitBreaker(config: cfg)
        breaker.recordFailure(now: t0)
        breaker.recordFailure(now: t0)

        let afterCooldown = t0.addingTimeInterval(100)
        XCTAssertTrue(breaker.canAttempt(now: afterCooldown), "Must allow at exactly cooldown expiry")
        XCTAssertEqual(breaker.state, .halfOpen)
    }

    // MARK: - Half-open → closed after success

    func testHalfOpenSuccessCloses() {
        let cfg = VIOSLCircuitBreaker.Config(maxConsecutiveFailures: 2, baseCooldown: 100)
        let breaker = VIOSLCircuitBreaker(config: cfg)
        breaker.recordFailure(now: t0)
        breaker.recordFailure(now: t0)
        _ = breaker.canAttempt(now: t0.addingTimeInterval(100)) // → halfOpen
        XCTAssertEqual(breaker.state, .halfOpen)
        breaker.recordSuccess()
        XCTAssertEqual(breaker.state, .closed)
        XCTAssertEqual(breaker.consecutiveFailures, 0)
    }

    // MARK: - Half-open → reopens after failure

    func testHalfOpenFailureReopens() {
        let cfg = VIOSLCircuitBreaker.Config(maxConsecutiveFailures: 2, baseCooldown: 100)
        let breaker = VIOSLCircuitBreaker(config: cfg)
        breaker.recordFailure(now: t0)
        breaker.recordFailure(now: t0)
        _ = breaker.canAttempt(now: t0.addingTimeInterval(100)) // → halfOpen
        // Recording a 3rd failure while halfOpen (consecutiveFailures=3 >= max=2)
        breaker.recordFailure(now: t0.addingTimeInterval(100))
        XCTAssertFalse(breaker.canAttempt(now: t0.addingTimeInterval(100)),
                       "After half-open failure, breaker must reopen")
    }

    // MARK: - Success resets failures

    func testSuccessResetsFailureCount() {
        let breaker = VIOSLCircuitBreaker(config: .init(maxConsecutiveFailures: 3))
        breaker.recordFailure(now: t0)
        breaker.recordFailure(now: t0)
        breaker.recordSuccess()
        XCTAssertEqual(breaker.consecutiveFailures, 0)
        XCTAssertEqual(breaker.state, .closed)
        XCTAssertTrue(breaker.canAttempt(now: t0))
    }

    // MARK: - Exponential backoff on cooldown

    func testCooldownDoublesOnSecondTrip() {
        let cfg = VIOSLCircuitBreaker.Config(
            maxConsecutiveFailures: 2,
            baseCooldown: 100,
            maxCooldown: 100_000,
            cooldownMultiplier: 2.0
        )
        let breaker = VIOSLCircuitBreaker(config: cfg)

        // Trip 1: cooldown = 100 * 2^0 = 100
        breaker.recordFailure(now: t0)
        breaker.recordFailure(now: t0)
        guard case .open(let until1) = breaker.state else {
            return XCTFail("Expected .open after first trip")
        }
        XCTAssertEqual(until1.timeIntervalSince(t0), 100, accuracy: 1)

        // Recover: probe, then full success
        _ = breaker.canAttempt(now: t0.addingTimeInterval(100))
        breaker.recordSuccess()

        // Trip 2: cooldown = 100 * 2^1 = 200
        breaker.recordFailure(now: t0)
        breaker.recordFailure(now: t0)
        guard case .open(let until2) = breaker.state else {
            return XCTFail("Expected .open after second trip")
        }
        XCTAssertEqual(until2.timeIntervalSince(t0), 200, accuracy: 1)
    }

    func testCooldownCappedAtMax() {
        let cfg = VIOSLCircuitBreaker.Config(
            maxConsecutiveFailures: 2,
            baseCooldown: 1000,
            maxCooldown: 1500,
            cooldownMultiplier: 2.0
        )
        let breaker = VIOSLCircuitBreaker(config: cfg)

        // Trip 1: 1000 (below cap)
        breaker.recordFailure(now: t0); breaker.recordFailure(now: t0)
        _ = breaker.canAttempt(now: t0.addingTimeInterval(1000))
        breaker.recordSuccess()

        // Trip 2: 2000 → capped at 1500
        breaker.recordFailure(now: t0); breaker.recordFailure(now: t0)
        guard case .open(let until) = breaker.state else {
            return XCTFail("Expected .open")
        }
        XCTAssertEqual(until.timeIntervalSince(t0), 1500, accuracy: 1)
    }
}
