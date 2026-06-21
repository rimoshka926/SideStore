import XCTest
@testable import VIOSLCore

final class SchedulerStateTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    private let threshold = 3.0

    private func makeScheduler(maxFailures: Int = 3) -> VIOSLSchedulerState {
        VIOSLSchedulerState(
            resignThresholdDays: threshold,
            breaker: VIOSLCircuitBreaker(
                config: .init(maxConsecutiveFailures: maxFailures, baseCooldown: 3600)
            )
        )
    }

    // MARK: - CHECK when days_left >= threshold

    func testCheckWhenDaysLeftExactlyAtThreshold() {
        XCTAssertEqual(makeScheduler().decide(daysLeft: 3.0, paused: false, now: t0), .check)
    }

    func testCheckWhenDaysLeftAboveThreshold() {
        XCTAssertEqual(makeScheduler().decide(daysLeft: 7.0, paused: false, now: t0), .check)
    }

    // MARK: - RESIGN when days_left < threshold

    func testResignWhenJustBelowThreshold() {
        XCTAssertEqual(makeScheduler().decide(daysLeft: 2.9, paused: false, now: t0), .resign)
    }

    func testResignWhenDaysLeftZero() {
        XCTAssertEqual(makeScheduler().decide(daysLeft: 0.0, paused: false, now: t0), .resign)
    }

    func testResignWhenDaysLeftNegative() {
        XCTAssertEqual(makeScheduler().decide(daysLeft: -1.0, paused: false, now: t0), .resign)
    }

    // MARK: - KEY INVARIANT: Zero Apple API calls above threshold

    /// Calling decide() 100 times with days_left >= threshold must never return .resign.
    /// This is the core "check ≠ auth" invariant that protects the burner Apple ID.
    func testZeroResignsWhenDaysLeftAboveThreshold() {
        let scheduler = makeScheduler()
        for _ in 0..<100 {
            let action = scheduler.decide(daysLeft: 4.0, paused: false, now: t0)
            XCTAssertEqual(action, .check,
                           "INVARIANT VIOLATED: must never resign when days_left >= threshold")
        }
    }

    // MARK: - Pause flag

    func testSkipWhenPausedBelowThreshold() {
        XCTAssertEqual(makeScheduler().decide(daysLeft: 1.0, paused: true, now: t0), .skip(.paused))
    }

    func testSkipWhenPausedAboveThreshold() {
        // Paused takes priority even when a check-only cycle would otherwise run
        XCTAssertEqual(makeScheduler().decide(daysLeft: 5.0, paused: true, now: t0), .skip(.paused))
    }

    func testSkipWhenPausedAndDaysLeftZero() {
        XCTAssertEqual(makeScheduler().decide(daysLeft: 0.0, paused: true, now: t0), .skip(.paused))
    }

    // MARK: - Missing cert data

    func testSkipWhenNoCertData() {
        XCTAssertEqual(makeScheduler().decide(daysLeft: nil, paused: false, now: t0), .skip(.noCertData))
    }

    func testSkipNoCertDataEvenWhenPaused() {
        // nil daysLeft → .noCertData is the first check; pause is not reached
        XCTAssertEqual(makeScheduler().decide(daysLeft: nil, paused: true, now: t0), .skip(.noCertData))
    }

    // MARK: - Circuit breaker integration

    func testSkipWhenBreakerOpen() {
        let s = makeScheduler(maxFailures: 2)
        s.breaker.recordFailure(now: t0)
        s.breaker.recordFailure(now: t0)
        XCTAssertEqual(s.decide(daysLeft: 1.0, paused: false, now: t0), .skip(.breakerOpen))
    }

    func testResignAllowedWhileBreakerClosed() {
        let s = makeScheduler(maxFailures: 3)
        s.breaker.recordFailure(now: t0) // 1/3 — still closed
        s.breaker.recordFailure(now: t0) // 2/3 — still closed
        XCTAssertEqual(s.decide(daysLeft: 1.0, paused: false, now: t0), .resign)
    }

    func testResignAllowedAfterBreakerCooldownExpires() {
        let cfg = VIOSLCircuitBreaker.Config(maxConsecutiveFailures: 2, baseCooldown: 100)
        let s = VIOSLSchedulerState(
            resignThresholdDays: threshold,
            breaker: VIOSLCircuitBreaker(config: cfg)
        )
        s.breaker.recordFailure(now: t0)
        s.breaker.recordFailure(now: t0)
        // After cooldown: peekCanAttempt returns true → decide() returns .resign
        let result = s.decide(daysLeft: 1.0, paused: false, now: t0.addingTimeInterval(101))
        XCTAssertEqual(result, .resign)
    }

    // MARK: - Idempotency: decide() must not mutate breaker state

    /// decide() uses peekCanAttempt() (read-only) so it must never modify the
    /// circuit breaker — neither failures nor the open→halfOpen transition.
    func testDecideNeverMutatesBreakerWhenClosed() {
        let s = makeScheduler()
        for i in 0..<5 {
            let action = s.decide(daysLeft: 1.0, paused: false, now: t0)
            XCTAssertEqual(action, .resign, "Call \(i): decide() must be consistent")
        }
        XCTAssertEqual(s.breaker.consecutiveFailures, 0,
                       "decide() must not record failures — caller's responsibility")
        XCTAssertEqual(s.breaker.state, .closed,
                       "decide() must not mutate breaker when it is closed")
    }

    func testDecideNeverMutatesBreakerWhenOpen() {
        let cfg = VIOSLCircuitBreaker.Config(maxConsecutiveFailures: 2, baseCooldown: 100)
        let s = VIOSLSchedulerState(resignThresholdDays: threshold, breaker: VIOSLCircuitBreaker(config: cfg))
        s.breaker.recordFailure(now: t0)
        s.breaker.recordFailure(now: t0)
        // Breaker is open; decide() should return .skip without touching state
        let result = s.decide(daysLeft: 1.0, paused: false, now: t0.addingTimeInterval(50))
        XCTAssertEqual(result, .skip(.breakerOpen))
        // State must still be .open (not halfOpen) because decide() uses peekCanAttempt
        if case .open(_) = s.breaker.state { /* pass */ } else {
            XCTFail("decide() must not transition open→halfOpen; that is canAttempt()'s job")
        }
    }

    func testDecideAllowsResignAfterCooldownWithoutTransitioningState() {
        let cfg = VIOSLCircuitBreaker.Config(maxConsecutiveFailures: 2, baseCooldown: 100)
        let s = VIOSLSchedulerState(resignThresholdDays: threshold, breaker: VIOSLCircuitBreaker(config: cfg))
        s.breaker.recordFailure(now: t0)
        s.breaker.recordFailure(now: t0)
        // After cooldown: peekCanAttempt returns true, decide() returns .resign
        let result = s.decide(daysLeft: 1.0, paused: false, now: t0.addingTimeInterval(101))
        XCTAssertEqual(result, .resign, "decide() must return .resign after cooldown")
        // Breaker state is still .open (not yet halfOpen) — that transition belongs to canAttempt()
        if case .open(_) = s.breaker.state { /* pass */ } else {
            XCTFail("decide() must NOT transition open→halfOpen; actual state: \(s.breaker.state)")
        }
    }

    // MARK: - Priority order: noCertData > paused > check/resign/breaker

    func testPriorityOrder() {
        let s = makeScheduler()
        // 1. nil → noCertData (highest priority)
        XCTAssertEqual(s.decide(daysLeft: nil, paused: true, now: t0), .skip(.noCertData))
        // 2. paused → skip.paused (beats resign and check)
        XCTAssertEqual(s.decide(daysLeft: 0.0, paused: true, now: t0), .skip(.paused))
        // 3. days_left >= threshold → check (beats resign)
        XCTAssertEqual(s.decide(daysLeft: 3.0, paused: false, now: t0), .check)
        // 4. days_left < threshold + breaker closed → resign
        XCTAssertEqual(s.decide(daysLeft: 1.0, paused: false, now: t0), .resign)
    }
}
