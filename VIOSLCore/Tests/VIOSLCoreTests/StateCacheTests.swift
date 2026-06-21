import XCTest
@testable import VIOSLCore

final class StateCacheTests: XCTestCase {

    // MARK: - empty sentinel

    func testEmptyHasNilDaysLeft() {
        XCTAssertNil(VIOSLStateCache.empty.daysLeft)
    }

    func testEmptyIsNotPaused() {
        XCTAssertFalse(VIOSLStateCache.empty.paused)
    }

    func testEmptyWarningIsOk() {
        XCTAssertEqual(VIOSLStateCache.empty.warning, "ok")
    }

    func testEmptyFetchedAtIsDistantPast() {
        XCTAssertEqual(VIOSLStateCache.empty.fetchedAt, .distantPast)
    }

    // MARK: - Codable round-trip (UserDefaults persistence format)

    func testRoundTripWithDaysLeft() throws {
        let original = VIOSLStateCache(daysLeft: 5.5, paused: false, warning: "ok", fetchedAt: .now)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VIOSLStateCache.self, from: data)
        XCTAssertEqual(decoded.daysLeft, 5.5)
        XCTAssertEqual(decoded.paused, false)
        XCTAssertEqual(decoded.warning, "ok")
    }

    func testRoundTripPaused() throws {
        let original = VIOSLStateCache(daysLeft: 1.2, paused: true, warning: "w1", fetchedAt: .now)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VIOSLStateCache.self, from: data)
        XCTAssertEqual(decoded.paused, true)
        XCTAssertEqual(decoded.warning, "w1")
    }

    func testRoundTripNilDaysLeft() throws {
        let original = VIOSLStateCache(daysLeft: nil, paused: false, warning: "ok", fetchedAt: .now)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VIOSLStateCache.self, from: data)
        XCTAssertNil(decoded.daysLeft)
    }

    func testRoundTripW0Warning() throws {
        let original = VIOSLStateCache(daysLeft: 0.3, paused: false, warning: "w0", fetchedAt: .now)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VIOSLStateCache.self, from: data)
        XCTAssertEqual(decoded.warning, "w0")
        XCTAssertEqual(decoded.daysLeft!, 0.3, accuracy: 0.001)
    }

    func testEquality() {
        let now = Date()
        let a = VIOSLStateCache(daysLeft: 3.0, paused: false, warning: "ok", fetchedAt: now)
        let b = VIOSLStateCache(daysLeft: 3.0, paused: false, warning: "ok", fetchedAt: now)
        XCTAssertEqual(a, b)
    }

    func testInequalityDaysLeft() {
        let now = Date()
        let a = VIOSLStateCache(daysLeft: 3.0, paused: false, warning: "ok", fetchedAt: now)
        let b = VIOSLStateCache(daysLeft: 2.0, paused: false, warning: "ok", fetchedAt: now)
        XCTAssertNotEqual(a, b)
    }

    func testInequalityPaused() {
        let now = Date()
        let a = VIOSLStateCache(daysLeft: 3.0, paused: false, warning: "ok", fetchedAt: now)
        let b = VIOSLStateCache(daysLeft: 3.0, paused: true, warning: "ok", fetchedAt: now)
        XCTAssertNotEqual(a, b)
    }
}
