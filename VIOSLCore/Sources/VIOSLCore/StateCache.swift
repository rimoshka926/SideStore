import Foundation

/// Testable model for the VIOSL backend state cache persisted in UserDefaults.
/// Mirrored in AltStore/VIOSL/VIOSLBackendPoller.swift (VIOSLStateCache) — keep structs in sync.
///
/// XCTest imports this from VIOSLCore; the app target uses the parallel AltStore copy
/// (AltStore doesn't import VIOSLCore to keep the dependency graph simple).
public struct VIOSLStateCache: Codable, Equatable {
    /// Days until certificate expiry. `nil` when backend has received no telemetry yet.
    public let daysLeft: Double?
    /// `true` when the operator paused auto-resign via `/pause` Telegram command.
    public let paused: Bool
    /// Warning level: "ok" | "w2" | "w1" | "w0".
    public let warning: String
    /// Timestamp when this snapshot was fetched from the backend.
    public let fetchedAt: Date

    public init(daysLeft: Double?, paused: Bool, warning: String, fetchedAt: Date) {
        self.daysLeft = daysLeft
        self.paused = paused
        self.warning = warning
        self.fetchedAt = fetchedAt
    }

    /// Sentinel for first run (no data yet). `paused` defaults to `false` so refresh proceeds.
    public static let empty = VIOSLStateCache(
        daysLeft: nil,
        paused: false,
        warning: "ok",
        fetchedAt: .distantPast
    )
}
