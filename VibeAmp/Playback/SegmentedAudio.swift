import Foundation
import Network

/// Describes the existing fragments; audio stays on the CDN and is never remuxed
/// or downloaded in full. Only the small MP4 index is read before playback.
struct AudioSegmentIndex: Equatable {
    struct Segment: Equatable {
        let offset: UInt64
        let size: UInt32
        let duration: Double
    }
    let initializationSize: Int
    let segments: [Segment]

    static func parse(_ data: Data) -> AudioSegmentIndex? {
        let bytes = [UInt8](data)
        func number(_ offset: Int, _ count: Int) -> UInt64? {
            guard offset >= 0, count <= bytes.count, offset <= bytes.count - count else { return nil }
            return bytes[offset..<(offset + count)].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        var cursor = 0
        var initializationEnd = 0
        var hasFileType = false
        while cursor + 8 <= bytes.count {
            guard let size32 = number(cursor, 4) else { return nil }
            let headerSize = size32 == 1 ? 16 : 8
            guard let size = size32 == 1 ? number(cursor + 8, 8) : size32,
                  size >= UInt64(headerSize), size <= UInt64(bytes.count - cursor) else { return nil }
            let end = cursor + Int(size)
            let type = String(bytes: bytes[(cursor + 4)..<(cursor + 8)], encoding: .ascii)
            if type == "ftyp" { hasFileType = true }
            if type == "moov" { initializationEnd = end }
            if type == "mdat" || type == "moof" { return nil }
            if type == "sidx" {
                guard hasFileType, initializationEnd > 0 else { return nil }
                let base = cursor + headerSize
                guard let version = number(base, 1), version <= 1,
                      let timescale = number(base + 8, 4), timescale > 0 else { return nil }
                let width = version == 0 ? 4 : 8
                guard let firstOffset = number(base + 12 + width, width) else { return nil }
                let countOffset = base + 12 + 2 * width + 2
                guard end >= countOffset + 2, let count = number(countOffset, 2), count > 0,
                      count <= UInt64(max(0, end - countOffset - 2) / 12),
                      firstOffset <= UInt64(Int64.max) - UInt64(end) else { return nil }
                var offset = UInt64(end) + firstOffset
                var entries: [Segment] = []
                for i in 0..<Int(count) {
                    let entry = countOffset + 2 + i * 12
                    guard let reference = number(entry, 4), reference > 0, reference < 0x80000000,
                          let duration = number(entry + 4, 4), duration > 0,
                          offset <= UInt64(Int64.max) - reference else { return nil }
                    entries.append(Segment(offset: offset, size: UInt32(reference), duration: Double(duration) / Double(timescale)))
                    offset += reference
                }
                return AudioSegmentIndex(initializationSize: initializationEnd, segments: entries)
            }
            cursor = end
        }
        return nil
    }

    func playlist(mediaURL: URL) -> String {
        let url = mediaURL.absoluteString
        let target = Int(ceil(segments.map(\.duration).max() ?? 1))
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(target)",
                     "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-MEDIA-SEQUENCE:0",
                     "#EXT-X-MAP:URI=\"\(url)\",BYTERANGE=\"\(initializationSize)@0\""]
        for segment in segments {
            lines += [String(format: "#EXTINF:%.6f,", locale: Locale(identifier: "en_US_POSIX"), segment.duration),
                      "#EXT-X-BYTERANGE:\(segment.size)@\(segment.offset)", url]
        }
        return (lines + ["#EXT-X-ENDLIST"]).joined(separator: "\n") + "\n"
    }
}

/// A loopback-only endpoint serves one in-memory playlist. It does not proxy
/// audio, expose files, or accept arbitrary URLs. Each load owns its lifetime.
final class SegmentedAudio: @unchecked Sendable {
    let url: URL
    private let listener: NWListener

    private init(url: URL, listener: NWListener) {
        self.url = url
        self.listener = listener
    }

    static func prepare(mediaURL: URL) async throws -> SegmentedAudio? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: mediaURL)
        let limit = 256 * 1024
        request.setValue("bytes=0-\(limit - 1)", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 206,
              http.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes 0-") == true else { return nil }
        var header = Data()
        for try await byte in bytes {
            header.append(byte)
            if header.count == limit { break }
        }
        try Task.checkCancellation()
        guard let index = AudioSegmentIndex.parse(header) else { return nil }
        return try await serve(playlist: index.playlist(mediaURL: mediaURL))
    }

    static func serve(playlist: String) async throws -> SegmentedAudio {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "VibeAmp.playlist")
        let path = "/\(UUID().uuidString)/audio.m3u8"
        let body = Data(playlist.utf8)
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            receiveRequest(connection, path: path, body: body, accumulated: Data())
            queue.asyncAfter(deadline: .now() + 5) { connection.cancel() }
        }
        let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
            let startup = PlaylistStartup() // Accessed only on the listener's serial queue.
            listener.stateUpdateHandler = { [weak listener] state in
                guard !startup.completed else { return }
                switch state {
                case .ready:
                    guard let port = listener?.port else { return }
                    startup.completed = true
                    continuation.resume(returning: port)
                case .failed(let error):
                    startup.completed = true
                    listener?.cancel()
                    continuation.resume(throwing: error)
                case .cancelled:
                    startup.completed = true
                    continuation.resume(throwing: CancellationError())
                default: break
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) { if !startup.completed { listener.cancel() } }
        }
        if Task.isCancelled { listener.cancel(); throw CancellationError() }
        return SegmentedAudio(url: URL(string: "http://127.0.0.1:\(port.rawValue)\(path)")!, listener: listener)
    }

    private static func receiveRequest(_ connection: NWConnection, path: String, body: Data, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, error in
            var request = accumulated
            request.append(data ?? Data())
            guard error == nil, request.count <= 8192 else { connection.cancel(); return }
            guard let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") else {
                if complete { connection.cancel() }
                else { receiveRequest(connection, path: path, body: body, accumulated: request) }
                return
            }
            let line = text.components(separatedBy: "\r\n")[0].split(separator: " ")
            let valid = line.count == 3 && line[1] == path && (line[0] == "GET" || line[0] == "HEAD")
            let payload = valid ? body : Data()
            var response = Data("HTTP/1.1 \(valid ? "200 OK" : "404 Not Found")\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(payload.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
            if line.first != "HEAD" { response.append(payload) }
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    deinit { listener.cancel() }
}

/// Mutable startup state is confined to the listener queue.
private final class PlaylistStartup: @unchecked Sendable {
    var completed = false
}
