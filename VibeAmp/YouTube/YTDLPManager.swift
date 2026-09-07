import Foundation
import Observation

/// Manages the bundled yt-dlp executable under
/// ~/Library/Application Support/VibeAmp/bin/yt-dlp
/// Download -> temp file -> validate -> atomic move -> chmod 755.
@MainActor
@Observable
final class YTDLPManager {
    enum Status: Equatable {
        case unknown
        case checking
        case downloading(progress: Double?)
        case ready
        case failed(String)
    }

    static let minBinaryBytes = 1_024 * 1_024
    static let releaseBase = "https://github.com/yt-dlp/yt-dlp/releases/latest/download"
    static let macOSAssetURL = "\(releaseBase)/yt-dlp_macos"

    var status: Status = .unknown
    var binaryURL: URL?

    var isReady: Bool {
        if case .ready = status { return binaryURL != nil }
        return false
    }

    static func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("VibeAmp", isDirectory: true)
    }

    static func binaryDirectory() -> URL {
        supportDirectory().appendingPathComponent("bin", isDirectory: true)
    }

    static func binaryURL() -> URL {
        binaryDirectory().appendingPathComponent("yt-dlp")
    }

    static func isUsableBinary(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else { return false }
        return size.intValue >= minBinaryBytes
    }

    /// Ensures yt-dlp exists, downloading it on first run.
    /// Reports progress through AppLog so the LOG window shows what happens.
    func ensure(log: AppLog? = nil) async {
        let destination = Self.binaryURL()
        if Self.isUsableBinary(at: destination) {
            binaryURL = destination
            status = .ready
            return
        }
        status = .checking
        do {
            try FileManager.default.createDirectory(
                at: Self.binaryDirectory(),
                withIntermediateDirectories: true
            )
            // Remove any truncated leftover so it is never treated as valid.
            try? FileManager.default.removeItem(at: destination)
            log?.info("Preparing multimedia dependencies…")
            log?.info("Downloading yt-dlp for macOS…")
            status = .downloading(progress: nil)
            try await download(urlString: Self.macOSAssetURL, to: destination, log: log)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            binaryURL = destination
            status = .ready
            log?.info("Multimedia dependencies ready")
        } catch {
            binaryURL = nil
            status = .failed(error.localizedDescription)
            log?.error("Error preparing multimedia dependencies: \(error.localizedDescription)")
        }
    }

    private func download(urlString: String, to destination: URL, log: AppLog?) async throws {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        let temporary = destination.appendingPathExtension("download")
        try? FileManager.default.removeItem(at: temporary)

        // Use URLSession with redirect-following download task.
        let (tempURL, response): (URL, URLResponse) = try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: url) { location, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let location, let response {
                    continuation.resume(returning: (location, response))
                } else {
                    continuation.resume(throwing: URLError(.unknown))
                }
            }
            task.resume()
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NSError(
                domain: "VibeAmp",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Dependency download failed with HTTP \(http.statusCode)"]
            )
        }

        let data = try Data(contentsOf: tempURL)
        guard data.count >= Self.minBinaryBytes else {
            throw NSError(
                domain: "VibeAmp",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Dependency download is implausibly small (\(data.count) bytes)"]
            )
        }
        try data.write(to: temporary, options: .atomic)
        // Atomic promotion into place.
        _ = try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        log?.info("Downloaded yt-dlp (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))")
    }
}
