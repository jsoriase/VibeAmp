import Foundation

/// YouTube operations via the managed yt-dlp binary.
/// Every call launches yt-dlp directly with separate arguments (no shell).
actor YouTubeService {
    private let runner = ProcessRunner()
    private var binaryURL: URL?
    private var log: AppLog?
    typealias StreamResolver = @Sendable (String) async throws -> YTDLPModels.StreamInfo
    private let resolver: StreamResolver?
    private let now: @Sendable () -> Date
    private let cacheCapacity: Int

    init(resolver: StreamResolver? = nil, now: @escaping @Sendable () -> Date = { Date() }, cacheCapacity: Int = 64) {
        self.resolver = resolver
        self.now = now
        self.cacheCapacity = max(1, cacheCapacity)
    }

    func configure(binaryURL: URL?, log: AppLog? = nil) {
        self.binaryURL = binaryURL
        self.log = log
    }

    /// Canonicalize only recognized YouTube hosts; unrelated URLs retain their
    /// query parameters and cannot collide with a YouTube video in the cache.
    nonisolated static func streamKey(for input: String) -> String {
        let clean = String(input.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2048))
        guard let host = URLComponents(string: clean)?.host?.lowercased(),
              ["youtube.com", "youtu.be", "youtube-nocookie.com"].contains(where: {
                  host == $0 || host.hasSuffix("." + $0)
              }),
              let id = Track.videoID(from: clean),
              id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return clean }
        return "https://www.youtube.com/watch?v=\(id)"
    }

    private func requireBinary() throws -> URL {
        guard let binaryURL, FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw NSError(
                domain: "VibeAmp",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Multimedia dependencies are unavailable"]
            )
        }
        return binaryURL
    }

    private func normalizedInput(_ input: String) -> String {
        String(input.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2048))
    }

    // MARK: - Search

    /// Debounced by the caller; stale results are discarded via sequence numbers there.
    /// Returns up to `limit` results.
    func search(query: String, limit: Int = 8) async throws -> [YTDLPModels.SearchResult] {
        let binary = try requireBinary()
        let clean = normalizedInput(query)
        guard !clean.isEmpty else { return [] }
        // ytsearchN: prefix makes yt-dlp perform the search itself.
        let stdout = try await runner.runChecked(
            executableURL: binary,
            arguments: [
                "ytsearch\(max(1, min(limit, 10))):\(clean)",
                "--dump-json",
                "--flat-playlist",
                "--no-playlist",
                "--no-warnings",
                "--socket-timeout", "15",
            ]
        )
        return Array(YTDLPModels.parseSearchOutput(stdout).prefix(limit))
    }

    // MARK: - URL resolution

    func resolveURL(_ urlString: String) async throws -> YTDLPModels.URLInfo {
        let binary = try requireBinary()
        let clean = normalizedInput(urlString)
        guard Track.isHttpURL(clean) else {
            throw NSError(
                domain: "VibeAmp",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid or unsafe URL"]
            )
        }
        let stdout = try await runner.runChecked(
            executableURL: binary,
            arguments: [
                clean,
                "--dump-single-json",
                "--flat-playlist",
                "--no-warnings",
                "--socket-timeout", "20",
            ]
        )
        guard let info = YTDLPModels.parseURLInfoJSON(stdout) else {
            throw NSError(
                domain: "VibeAmp",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Could not understand this URL"]
            )
        }
        return info
    }

    // MARK: - Stream resolution (AVFoundation-friendly)

    private struct CachedStream {
        var info: YTDLPModels.StreamInfo
        var expiresAt: Date
        var lastAccess: UInt64
    }

    private struct Resolution {
        var id: UUID
        var task: Task<YTDLPModels.StreamInfo, Error>
    }

    // Both completed and in-flight work use the same canonical identity.
    // The service owns these tasks, so cancelling one caller never discards a
    // resolution that playback (or another caller) can still reuse.
    private var streamCache: [String: CachedStream] = [:]
    private var inFlight: [String: Resolution] = [:]
    private var accessCounter: UInt64 = 0

    func stream(urlString: String) async throws -> YTDLPModels.StreamInfo {
        try await sharedStream(urlString: urlString, prefetch: false, fresh: false)
    }

    func cachedStream(for urlString: String) -> YTDLPModels.StreamInfo? {
        validCachedStream(for: Self.streamKey(for: urlString))
    }

    /// Best-effort URL preparation, with the same cache and in-flight registry
    /// as playback. Failures are logged by the resolution task, never hidden.
    func prefetch(urlString: String) async {
        do {
            _ = try await sharedStream(urlString: urlString, prefetch: true, fresh: false)
        } catch is CancellationError {
            // Caller cancellation does not cancel the service-owned task.
        } catch {
            // sharedStream has already recorded the failure in AppLog.
        }
    }

    /// Bypass a failed cached URL. Concurrent fresh requests share one new
    /// extraction, and the invalid URL is removed even if that extraction fails.
    func resolveFreshStream(urlString: String) async throws -> YTDLPModels.StreamInfo {
        try await sharedStream(urlString: urlString, prefetch: false, fresh: true)
    }

    private func sharedStream(urlString: String, prefetch: Bool, fresh: Bool) async throws -> YTDLPModels.StreamInfo {
        try Task.checkCancellation()
        let key = Self.streamKey(for: urlString)
        let label = Self.streamLabel(key)
        let category = prefetch ? "PREFETCH" : "CACHE"
        guard Track.isHttpURL(key) else {
            await record(.warning, "[\(category)] Invalid stream URL")
            throw NSError(domain: "VibeAmp", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid or unsafe URL"])
        }
        let hadCachedEntry = streamCache[key] != nil
        if fresh {
            streamCache.removeValue(forKey: key)
        } else if let cached = validCachedStream(for: key) {
            await record(.info, "[\(category)] Cache hit: \(label) — reusing audio URL")
            try Task.checkCancellation()
            return cached
        }
        if let existing = inFlight[key] {
            await record(.info, "[\(category)] Joining in-flight resolution: \(label)")
            let result = try await existing.task.value
            try Task.checkCancellation()
            return result
        }

        let id = UUID()
        let started = now()
        let reason = fresh ? "Forced refresh" : (hadCachedEntry ? "Expired URL" : "Cache miss")
        // Register before any suspension (including logging) to prevent actor
        // reentrancy from starting two yt-dlp processes for the same video.
        let task = Task { [self] () throws -> YTDLPModels.StreamInfo in
            await record(.info, "[\(category)] \(reason); resolving URL: \(label)")
            do {
                let info = try await resolveUncached(key)
                try Task.checkCancellation()
                let expiresAt = YTDLPModels.streamExpiry(from: info.streamURL, now: now())
                if inFlight[key]?.id == id {
                    inFlight.removeValue(forKey: key)
                    cache(info, for: key, expiresAt: expiresAt)
                }
                let elapsed = String(format: "%.2f", now().timeIntervalSince(started))
                if expiresAt > now() {
                    let ttl = Int(expiresAt.timeIntervalSince(now()))
                    await record(.info, "[\(category)] Ready: \(label) in \(elapsed)s — URL cached for \(ttl)s")
                } else {
                    await record(.warning, "[\(category)] Resolved URL already expired: \(label); not cached")
                }
                return info
            } catch {
                if inFlight[key]?.id == id { inFlight.removeValue(forKey: key) }
                await record(prefetch ? .warning : .error,
                             "[\(category)] Resolution failed: \(label) — \(error.localizedDescription)")
                throw error
            }
        }
        inFlight[key] = Resolution(id: id, task: task)
        let result = try await task.value
        try Task.checkCancellation()
        return result
    }

    private func validCachedStream(for key: String) -> YTDLPModels.StreamInfo? {
        guard var cached = streamCache[key] else { return nil }
        guard cached.expiresAt > now() else {
            streamCache.removeValue(forKey: key)
            return nil
        }
        accessCounter += 1
        cached.lastAccess = accessCounter
        streamCache[key] = cached
        return cached.info
    }

    private func cache(_ info: YTDLPModels.StreamInfo, for key: String, expiresAt: Date) {
        let date = now()
        streamCache = streamCache.filter { $0.value.expiresAt > date }
        guard expiresAt > date else { return }
        accessCounter += 1
        streamCache[key] = CachedStream(info: info, expiresAt: expiresAt, lastAccess: accessCounter)
        while streamCache.count > cacheCapacity {
            guard let oldest = streamCache.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key else { break }
            streamCache.removeValue(forKey: oldest)
        }
    }

    private func record(_ level: LogLevel, _ message: String) async {
        await log?.log(level, message)
    }

    private nonisolated static func streamLabel(_ key: String) -> String {
        // Log video identity, never signed CDN URLs or unrelated URL queries.
        if key.hasPrefix("https://www.youtube.com/watch?v=") {
            return "YouTube \(Track.videoID(from: key) ?? "video")"
        }
        return URLComponents(string: key)?.host ?? "stream"
    }

    private func resolveUncached(_ key: String) async throws -> YTDLPModels.StreamInfo {
        if let resolver { return try await resolver(key) }
        let binary = try requireBinary()
        // `--print` answers in ~1 KB instead of `--dump-json`'s ~600 KB;
        // same extraction work, far less IPC and parsing.
        let stdout = try await runner.runChecked(
            executableURL: binary,
            arguments: [
                key,
                "--format", "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/bestaudio/best",
                "--no-playlist",
                "--no-warnings",
                "--skip-download",
                "--socket-timeout", "20",
                "--print", "url",
                "--print", "ext",
                "--print", "acodec",
                "--print", "abr",
                "--print", "asr",
            ]
        )
        guard let info = YTDLPModels.parsePrintedStream(stdout) else {
            throw NSError(
                domain: "VibeAmp",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Could not resolve an audio stream"]
            )
        }
        return info
    }

    /// Kept for callers that explicitly want a fresh resolve by the old name.
    func resolveStream(urlString: String) async throws -> YTDLPModels.StreamInfo {
        try await resolveFreshStream(urlString: urlString)
    }
}
