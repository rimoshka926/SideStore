import Foundation
import os.log

// MARK: - VIOSLStateCache

/// Cached snapshot of the backend GET /state response, persisted in UserDefaults.
/// Keeps the last known paused flag and daysLeft so gate decisions survive app restarts.
struct VIOSLStateCache: Codable {
    let daysLeft: Double?
    let paused: Bool
    let warning: String
    let fetchedAt: Date

    /// Sentinel used when no cache exists yet (first run).
    static let empty = VIOSLStateCache(daysLeft: nil, paused: false, warning: "ok", fetchedAt: .distantPast)
}

// MARK: - VIOSLBackendPoller

/// Polls the VIOSL backend GET /state endpoint and caches the result in UserDefaults.
///
/// Keeps background fetch gate decisions independent of network availability: gate reads
/// from cached state synchronously; cache is refreshed asynchronously on launch/background.
///
/// Pure logic is mirrored in VIOSLCore/Sources/VIOSLCore/StateCache.swift for XCTest.
actor VIOSLBackendPoller {

    static let shared = VIOSLBackendPoller()

    private let session: URLSession
    private let log = Logger(subsystem: "io.viosl.SideStore", category: "BackendPoller")

    private let cacheKey = "viosl.backend.state_cache"
    /// Staleness threshold: refresh if cache older than 30 min.
    private let cacheTTL: TimeInterval = 30 * 60

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public API

    /// Fetches fresh /state from the backend and persists the result.
    /// Safe to call from Task { } in any async context; no-ops on network failure (cache stays).
    func refreshCache() async {
        guard let url = URL(string: "state", relativeTo: VIOSLConfig.telemetryURL) else { return }
        let request = URLRequest(url: url, timeoutInterval: 10)
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                log.warning("BackendPoller: /state HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0, privacy: .public)")
                return
            }
            let raw = try JSONDecoder().decode(RawState.self, from: data)
            let cache = VIOSLStateCache(
                daysLeft: raw.days_left,
                paused: raw.paused ?? false,
                warning: raw.warning ?? "ok",
                fetchedAt: Date()
            )
            saveCache(cache)
            log.info("BackendPoller: cached — daysLeft=\(raw.days_left ?? -1, privacy: .public) paused=\(raw.paused ?? false, privacy: .public)")
        } catch {
            log.warning("BackendPoller: /state unreachable — \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Synchronous read of the last cached state.  Never blocks; returns `.empty` on first run.
    /// Safe to call from any thread (nonisolated + UserDefaults read).
    nonisolated func cachedState() -> VIOSLStateCache {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let cache = try? JSONDecoder().decode(VIOSLStateCache.self, from: data)
        else { return .empty }
        return cache
    }

    // MARK: - Private

    private struct RawState: Decodable {
        let days_left: Double?
        let paused: Bool?
        let warning: String?
    }

    private func saveCache(_ cache: VIOSLStateCache) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }
}
