import Foundation

/// YouTube operations via the managed yt-dlp binary.
/// Every call launches yt-dlp directly with separate arguments (no shell).
actor YouTubeService {
    private let runner = ProcessRunner()
    private var binaryURL: URL?

    func configure(binaryURL: URL?) {
        self.binaryURL = binaryURL
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

    struct CachedStream: Sendable {
        var info: YTDLPModels.StreamInfo
        var expiresAt: Date
    }

    /// Session cache of resolved CDN URLs keyed by normalized YouTube URL.
    /// Stream URLs expire (GoogleVideo `expire`), so entries carry the parsed
    /// expiry minus skew. Makes replay / prev / re-click instant and lets the
    /// next track be prefetched while the current one plays.
    private var streamCache: [String: CachedStream] = [:]
    private static let maxCachedStreams = 64

    /// Cached when valid, otherwise resolves over the network.
    func stream(urlString: String) async throws -> YTDLPModels.StreamInfo {
        let clean = normalizedInput(urlString)
        if let cached = streamCache[clean], cached.expiresAt > Date() {
            return cached.info
        }
        return try await resolveFreshStream(urlString: clean)
    }

    /// Valid cached entry without resolving, for cache-hit logging.
    func cachedStream(for urlString: String) -> YTDLPModels.StreamInfo? {
        let clean = normalizedInput(urlString)
        guard let cached = streamCache[clean], cached.expiresAt > Date() else { return nil }
        return cached.info
    }

    /// Best-effort background resolution for upcoming tracks. Errors are
    /// swallowed — a failed prefetch just means a normal resolve on demand.
    func prefetch(urlString: String) async {
        let clean = normalizedInput(urlString)
        guard Track.isHttpURL(clean) else { return }
        if let cached = streamCache[clean], cached.expiresAt > Date() { return }
        _ = try? await resolveFreshStream(urlString: clean)
    }

    /// Always resolves over the network (playback-failure retry path).
    /// Prefers M4A/AAC so AVPlayer can reliably consume the stream:
    ///   bestaudio[ext=m4a] / bestaudio[acodec^=mp4a] / bestaudio
    /// yt-dlp verifies this syntax at runtime; if a selector matches nothing
    /// it falls through to the next alternative.
    func resolveFreshStream(urlString: String) async throws -> YTDLPModels.StreamInfo {
        let binary = try requireBinary()
        let clean = normalizedInput(urlString)
        guard Track.isHttpURL(clean) else {
            throw NSError(
                domain: "VibeAmp",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid or unsafe URL"]
            )
        }
        // `--print` answers in ~1 KB instead of `--dump-json`'s ~600 KB;
        // same extraction work, far less IPC and parsing.
        let stdout = try await runner.runChecked(
            executableURL: binary,
            arguments: [
                clean,
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
        streamCache[clean] = CachedStream(
            info: info,
            expiresAt: YTDLPModels.streamExpiry(from: info.streamURL)
        )
        if streamCache.count > Self.maxCachedStreams {
            streamCache = streamCache.filter { $0.value.expiresAt > Date() }
        }
        return info
    }

    /// Kept for callers that explicitly want a fresh resolve by the old name.
    func resolveStream(urlString: String) async throws -> YTDLPModels.StreamInfo {
        try await resolveFreshStream(urlString: urlString)
    }
}
