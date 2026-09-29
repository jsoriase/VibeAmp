import Foundation

/// Decoded yt-dlp payloads. Parsing is isolated here so it is unit-testable
/// without spawning processes or touching the network.
enum YTDLPModels {
    struct SearchResult: Sendable, Equatable {
        var id: String
        var title: String
        var uploader: String
        var durationString: String
        var durationSeconds: Double?
        var webpageURL: String
        var thumbnailURL: String
    }

    struct StreamInfo: Sendable, Equatable {
        var streamURL: String
        var bitrateKbps: Int
        var sampleRateKHz: Int
        var codec: String
        var ext: String
        var durationSeconds: Double? = nil
    }

    enum URLInfo: Sendable, Equatable {
        case video(Track)
        case playlist(title: String, entries: [Track])
    }

    // MARK: - Search parsing (one JSON object per line)

    static func parseSearchLine(_ line: String) -> SearchResult? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        let title = (json["title"] as? String) ?? "Untitled"
        let uploader = (json["uploader"] as? String)
            ?? (json["channel"] as? String)
            ?? (json["channel_name"] as? String) ?? ""
        let durationString = (json["duration_string"] as? String) ?? formatDuration(json["duration"])
        let durationSeconds = doubleValue(json["duration"])
        let webpageURL = (json["webpage_url"] as? String)
            ?? (json["url"] as? String).flatMap { $0.hasPrefix("http") ? $0 : nil }
            ?? "https://www.youtube.com/watch?v=\(id)"
        let thumbnailURL = bestThumbnail(from: json) ?? ""
        return SearchResult(
            id: id,
            title: title,
            uploader: uploader,
            durationString: durationString,
            durationSeconds: durationSeconds,
            webpageURL: webpageURL,
            thumbnailURL: thumbnailURL
        )
    }

    static func parseSearchOutput(_ stdout: String) -> [SearchResult] {
        stdout.split(separator: "\n").compactMap { parseSearchLine(String($0)) }
    }

    // MARK: - Stream parsing (--print url/ext/acodec/abr/asr/duration, one per line)

    /// Parses the lightweight `--print` output for a single resolved stream.
    /// Preferred over `--dump-json` (which dumps ~600 KB of every format):
    /// same extraction, a ~1 KB answer, trivial parsing.
    static func parsePrintedStream(_ stdout: String) -> StreamInfo? {
        let lines = stdout
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.count >= 5 else { return nil }
        let url = lines[0]
        guard !url.isEmpty, url.hasPrefix("http") else { return nil }
        let ext = lines[1] == "NA" ? "" : lines[1]
        let codec = lines[2] == "NA" ? "" : lines[2]
        let bitrate = Double(lines[3]).map { Int($0) } ?? 128
        let sampleRate = Double(lines[4]).map { Int(($0 / 1000).rounded()) } ?? 44
        let duration = lines.count > 5 ? Double(lines[5]) : nil
        return StreamInfo(
            streamURL: url,
            bitrateKbps: bitrate,
            sampleRateKHz: sampleRate,
            codec: codec,
            ext: ext,
            durationSeconds: duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        )
    }

    // MARK: - Stream-URL cache expiry

    /// GoogleVideo URLs carry `expire=<unix>`; refresh a few minutes early.
    /// URLs without it get a conservative default TTL (they still expire —
    /// a failed playback always re-resolves exactly once).
    static let streamCacheSkew: TimeInterval = 300
    static let streamCacheDefaultTTL: TimeInterval = 4 * 3600

    static func streamExpiry(from streamURL: String, now: Date = Date()) -> Date {
        if let components = URLComponents(string: streamURL),
           let raw = components.queryItems?.first(where: { $0.name == "expire" })?.value,
           let seconds = TimeInterval(raw) {
            return Date(timeIntervalSince1970: max(0, seconds - streamCacheSkew))
        }
        return now.addingTimeInterval(streamCacheDefaultTTL)
    }

    // MARK: - URL info parsing (video or flat playlist)

    static func parseURLInfoJSON(_ stdout: String) -> URLInfo? {
        guard let data = stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let type = (json["_type"] as? String) ?? ""
        if type == "playlist" || json["entries"] is [[String: Any]] {
            let title = (json["title"] as? String) ?? "YouTube Playlist"
            let rawEntries = (json["entries"] as? [[String: Any]]) ?? []
            let entries: [Track] = rawEntries.compactMap { entry in
                guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
                // Skip deleted/private entries which have no title/url.
                let entryURL = (entry["url"] as? String).flatMap { $0.hasPrefix("http") ? $0 : nil }
                    ?? "https://www.youtube.com/watch?v=\(id)"
                return Track(
                    id: id,
                    title: (entry["title"] as? String) ?? "Untitled",
                    uploader: (entry["uploader"] as? String) ?? (entry["channel"] as? String) ?? "",
                    durationString: (entry["duration_string"] as? String) ?? formatDuration(entry["duration"]),
                    durationSeconds: doubleValue(entry["duration"]),
                    webpageURL: entryURL,
                    thumbnailURL: bestThumbnail(from: entry) ?? (entry["thumbnail"] as? String ?? "")
                )
            }
            return .playlist(title: title, entries: entries)
        }

        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        // Highest-resolution thumbnail is last in yt-dlp's list.
        let track = Track(
            id: id,
            title: (json["title"] as? String) ?? "Untitled",
            uploader: (json["uploader"] as? String) ?? (json["channel"] as? String) ?? "",
            durationString: (json["duration_string"] as? String) ?? formatDuration(json["duration"]),
            durationSeconds: doubleValue(json["duration"]),
            webpageURL: (json["webpage_url"] as? String) ?? "https://www.youtube.com/watch?v=\(id)",
            thumbnailURL: bestThumbnail(from: json) ?? (json["thumbnail"] as? String ?? "")
        )
        return .video(track)
    }

    // MARK: - Helpers

    static func bestThumbnail(from json: [String: Any]) -> String? {
        if let thumbs = json["thumbnails"] as? [[String: Any]], !thumbs.isEmpty {
            // Prefer the highest-resolution thumbnail (usually last).
            for candidate in thumbs.reversed() {
                if let url = candidate["url"] as? String, !url.isEmpty {
                    return url
                }
            }
        }
        if let url = json["thumbnail"] as? String, !url.isEmpty {
            return url
        }
        return nil
    }

    static func doubleValue(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    /// Formats seconds as M:SS or H:MM:SS. Used when duration_string is absent.
    static func formatDuration(_ seconds: Double) -> String {
        TimeFormatting.format(seconds: seconds)
    }

    static func formatDuration(_ value: Any?) -> String {
        guard let seconds = doubleValue(value), seconds.isFinite, seconds > 0 else { return "" }
        return TimeFormatting.format(seconds: seconds)
    }
}

/// Shared time formatting (player LCD, mini player, search results).
enum TimeFormatting: Sendable {
    static func format(seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    static func formatCounter(current: Double, duration: Double) -> String {
        // Player LCD shows elapsed MM:SS.
        guard current.isFinite, current >= 0 else { return "00:00" }
        let total = Int(current)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
