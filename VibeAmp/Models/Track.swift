import Foundation

/// A single playable queue entry. Persisted between launches.
/// Never persists resolved CDN stream URLs — only the original YouTube identity.
struct Track: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var uploader: String
    var durationString: String
    var durationSeconds: Double?
    var webpageURL: String
    var thumbnailURL: String

    /// Canonical URL used for stream resolution.
    var url: String { webpageURL }

    init(
        id: String,
        title: String,
        uploader: String = "",
        durationString: String = "",
        durationSeconds: Double? = nil,
        webpageURL: String,
        thumbnailURL: String = ""
    ) {
        self.id = id
        self.title = title
        self.uploader = uploader
        self.durationString = durationString
        self.durationSeconds = durationSeconds
        self.webpageURL = webpageURL
        self.thumbnailURL = thumbnailURL
    }

    /// YouTube video ID extraction for youtu.be / watch / shorts / embed forms.
    static func videoID(from urlString: String) -> String? {
        guard let components = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host?.lowercased()
        else { return nil }
        if host.contains("youtu.be") {
            let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let candidate = path.split(separator: "/").first.map(String.init) ?? ""
            return candidate.isEmpty ? nil : candidate
        }
        if host.contains("youtube.com") || host.contains("youtube-nocookie.com") {
            if let queryItems = components.queryItems,
               let v = queryItems.first(where: { $0.name == "v" })?.value, !v.isEmpty {
                return v
            }
            let pathParts = components.path.split(separator: "/").map(String.init)
            if pathParts.count >= 2 && ["shorts", "embed", "live", "v"].contains(pathParts[0]) {
                return pathParts[1]
            }
        }
        return nil
    }

    static func isYouTubePlaylistURL(_ urlString: String) -> Bool {
        guard let components = URLComponents(string: urlString),
              let host = components.host?.lowercased(),
              host.contains("youtube.com") || host.contains("youtu.be")
        else { return false }
        return components.queryItems?.contains(where: { $0.name == "list" && !($0.value?.isEmpty ?? true) }) ?? false
    }

    static func isHttpURL(_ value: String) -> Bool {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
