import XCTest
@testable import VibeAmp

@MainActor
final class YouTubeServiceTests: XCTestCase {
    private func url(_ id: String) -> String { "https://www.youtube.com/watch?v=\(id)" }

    func testYouTubeVariantsShareOneCachedResolution() async throws {
        let fake = StreamResolverStub()
        let service = YouTubeService(resolver: { try await fake.resolve($0) })
        for value in [url("abc"), "https://youtu.be/abc?t=20", "https://m.youtube.com/watch?v=abc&list=xyz",
                      "https://www.youtube.com/shorts/abc", "https://www.youtube-nocookie.com/embed/abc"] {
            _ = try await service.stream(urlString: value)
        }
        let calls = await fake.calls
        XCTAssertEqual(calls, [url("abc")])
        XCTAssertNotEqual(YouTubeService.streamKey(for: "https://youtube.com.example.org/watch?v=abc"), url("abc"))
        XCTAssertNotEqual(YouTubeService.streamKey(for: "https://notyoutu.be/abc"), url("abc"))
        XCTAssertEqual(YouTubeService.streamKey(for: "https://cdn.example/a?token=123"), "https://cdn.example/a?token=123")
    }

    func testCompletedPrefetchIsReusedByPlayback() async throws {
        let fake = StreamResolverStub()
        let log = AppLog()
        let service = YouTubeService(resolver: { try await fake.resolve($0) })
        await service.configure(binaryURL: nil, log: log)
        await service.prefetch(urlString: "https://youtu.be/abc")
        _ = try await service.stream(urlString: url("abc"))
        let count = await fake.calls.count
        XCTAssertEqual(count, 1)
        XCTAssertTrue(log.entries.contains { $0.message.contains("[PREFETCH] Ready") })
        XCTAssertTrue(log.entries.contains { $0.message.contains("[CACHE] Cache hit") })
    }

    func testPlaybackJoinsPrefetchEvenWhenPrefetchCallerIsCancelled() async throws {
        let fake = StreamResolverStub(hold: true)
        let log = AppLog()
        let service = YouTubeService(resolver: { try await fake.resolve($0) })
        await service.configure(binaryURL: nil, log: log)
        let prefetch = Task { await service.prefetch(urlString: "https://youtu.be/abc") }
        try await waitUntil { await fake.calls.count == 1 }
        prefetch.cancel()
        let playback = Task { try await service.stream(urlString: self.url("abc")) }
        try await waitUntil { log.entries.contains { $0.message.contains("Joining in-flight") } }
        await fake.release()
        let result = try await playback.value
        await prefetch.value
        let count = await fake.calls.count
        let cached = await service.cachedStream(for: url("abc"))
        XCTAssertEqual(count, 1)
        XCTAssertEqual(cached, result)
        XCTAssertTrue(log.entries.contains { $0.message.contains("[PREFETCH] Ready") })
    }

    func testConcurrentPlaybackRequestsShareOneResolution() async throws {
        let fake = StreamResolverStub(hold: true)
        let log = AppLog()
        let service = YouTubeService(resolver: { try await fake.resolve($0) })
        await service.configure(binaryURL: nil, log: log)
        let first = Task { try await service.stream(urlString: self.url("abc")) }
        try await waitUntil { await fake.calls.count == 1 }
        let second = Task { try await service.stream(urlString: "https://youtu.be/abc") }
        try await waitUntil { log.entries.contains { $0.message.contains("Joining in-flight") } }
        await fake.release()
        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual(firstResult, secondResult)
        let count = await fake.calls.count
        XCTAssertEqual(count, 1)
    }

    func testFailedPrefetchIsLoggedAndCanBeRetried() async throws {
        let fake = StreamResolverStub()
        await fake.failNext()
        let log = AppLog()
        let service = YouTubeService(resolver: { try await fake.resolve($0) })
        await service.configure(binaryURL: nil, log: log)
        await service.prefetch(urlString: url("abc"))
        let cached = await service.cachedStream(for: url("abc"))
        XCTAssertNil(cached)
        XCTAssertTrue(log.entries.contains { $0.level == .warning && $0.message.contains("[PREFETCH] Resolution failed") })
        _ = try await service.stream(urlString: url("abc"))
        let count = await fake.calls.count
        XCTAssertEqual(count, 2)
    }

    func testForcedRefreshRemovesBadCachedURLWhenRetryFails() async throws {
        let fake = StreamResolverStub()
        let service = YouTubeService(resolver: { try await fake.resolve($0) })
        _ = try await service.stream(urlString: url("abc"))
        await fake.failNext()
        do {
            _ = try await service.resolveFreshStream(urlString: "https://youtu.be/abc")
            XCTFail("Expected resolver failure")
        } catch {}
        let cached = await service.cachedStream(for: url("abc"))
        XCTAssertNil(cached)
        _ = try await service.stream(urlString: url("abc"))
        let count = await fake.calls.count
        XCTAssertEqual(count, 3)
    }

    func testExpiryTriggersNewResolution() async throws {
        let clock = CacheTestClock()
        let fake = StreamResolverStub()
        let log = AppLog()
        let service = YouTubeService(resolver: { try await fake.resolve($0) }, now: { clock.now })
        await service.configure(binaryURL: nil, log: log)
        _ = try await service.stream(urlString: url("abc"))
        clock.advance(YTDLPModels.streamCacheDefaultTTL + 1)
        _ = try await service.stream(urlString: url("abc"))
        let count = await fake.calls.count
        XCTAssertEqual(count, 2)
        XCTAssertTrue(log.entries.contains { $0.message.contains("Expired URL") })
    }

    func testCacheEvictsLeastRecentlyUsedEntryEvenWhenAllURLsAreValid() async throws {
        let fake = StreamResolverStub()
        let service = YouTubeService(resolver: { try await fake.resolve($0) }, cacheCapacity: 2)
        for id in ["a", "b", "a", "c"] { _ = try await service.stream(urlString: url(id)) }
        let a = await service.cachedStream(for: url("a"))
        let b = await service.cachedStream(for: url("b"))
        let c = await service.cachedStream(for: url("c"))
        XCTAssertNotNil(a)
        XCTAssertNil(b)
        XCTAssertNotNil(c)
        _ = try await service.stream(urlString: url("b"))
        let count = await fake.calls.count
        XCTAssertEqual(count, 4)
    }

    func testQueueEditsUpdatePrefetchAndEmptyTailIsLogged() async throws {
        let fake = StreamResolverStub()
        let service = YouTubeService(resolver: { try await fake.resolve($0) })
        let log = AppLog()
        await service.configure(binaryURL: nil, log: log)
        let tracks = ["a", "b", "c"].map { Track(id: $0, title: $0, webpageURL: url($0)) }
        let queue = QueueStore(entries: [tracks[0]], currentIndex: 0)
        let playback = PlaybackController()
        playback.queue = queue
        playback.youtube = service
        playback.log = log
        playback.currentTrack = tracks[0]
        playback.status = .playing
        playback.refreshPrefetch()
        playback.refreshPrefetch()
        XCTAssertEqual(log.entries.filter { $0.message.contains("no next track") }.count, 1)
        queue.entries.append(contentsOf: tracks.dropFirst())
        playback.refreshPrefetch()
        try await waitUntil { await fake.calls.count == 1 }
        queue.move(from: IndexSet(integer: 2), to: 1)
        playback.refreshPrefetch()
        try await waitUntil { await fake.calls.count == 2 }
        let calls = await fake.calls
        XCTAssertEqual(calls, [url("b"), url("c")])
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for test resolver")
        throw CocoaError(.coderInvalidValue)
    }
}

private actor StreamResolverStub {
    private(set) var calls: [String] = []
    private var hold: Bool
    private var fail = false
    private var pending: [CheckedContinuation<Void, Never>] = []
    init(hold: Bool = false) { self.hold = hold }
    func failNext() { fail = true }
    func resolve(_ url: String) async throws -> YTDLPModels.StreamInfo {
        calls.append(url)
        if hold { await withCheckedContinuation { pending.append($0) } }
        if fail { fail = false; throw CocoaError(.fileReadUnknown) }
        return YTDLPModels.StreamInfo(streamURL: "https://cdn.example/audio.m4a", bitrateKbps: 128,
                                     sampleRateKHz: 44, codec: "mp4a.40.2", ext: "m4a")
    }
    func release() {
        hold = false
        let waiters = pending
        pending.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private final class CacheTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}
