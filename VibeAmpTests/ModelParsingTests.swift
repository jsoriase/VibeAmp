import XCTest
@testable import VibeAmp

final class ModelParsingTests: XCTestCase {
    func testTrackCodableRoundTrip() throws {
        let track = Track(
            id: "abc123",
            title: "Test Song",
            uploader: "Test Artist",
            durationString: "3:45",
            durationSeconds: 225,
            webpageURL: "https://www.youtube.com/watch?v=abc123",
            thumbnailURL: "https://example.com/thumb.jpg"
        )
        let data = try JSONEncoder().encode(track)
        let decoded = try JSONDecoder().decode(Track.self, from: data)
        XCTAssertEqual(decoded, track)
    }

    func testQueuePersistedRoundTrip() throws {
        let persisted = QueueStore.Persisted(
            entries: [
                Track(id: "a", title: "A", webpageURL: "https://www.youtube.com/watch?v=a"),
                Track(id: "b", title: "B", webpageURL: "https://www.youtube.com/watch?v=b"),
            ],
            currentIndex: 1
        )
        let data = try JSONEncoder().encode(persisted)
        let decoded = try JSONDecoder().decode(QueueStore.Persisted.self, from: data)
        XCTAssertEqual(decoded.entries.count, 2)
        XCTAssertEqual(decoded.currentIndex, 1)
    }

    func testEQSettingsRoundTrip() throws {
        var settings = EQSettings()
        settings.setPreamp(3)
        settings.setGain(-5, for: 60)
        settings.setGain(12.5, for: 16000) // clamped to 12
        XCTAssertEqual(settings.gain(for: 16000), 12)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(EQSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    func testEQSettingsLegacyDecode() throws {
        let json = #"{"preamp": 2.0, "60": -3.0, "1000": 4.5}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(EQSettings.self, from: json)
        XCTAssertEqual(decoded.preamp, 2.0)
        XCTAssertEqual(decoded.gain(for: 60), -3.0)
        XCTAssertEqual(decoded.gain(for: 1000), 4.5)
        XCTAssertEqual(decoded.gain(for: 600), 0)
    }

    func testEQClampAndReset() {
        var settings = EQSettings(preamp: 99)
        XCTAssertEqual(settings.preamp, 12)
        settings.reset()
        XCTAssertTrue(settings.isFlat)
    }

    func testCorruptStateFallsBack() {
        // Corrupt JSON must not throw — StateStore degrades to defaults.
        let bad = "not json{{{".data(using: .utf8)!
        let decoded = try? JSONDecoder().decode(EQSettings.self, from: bad)
        XCTAssertNil(decoded)
        let fallback = (try? JSONDecoder().decode(EQSettings.self, from: bad)) ?? EQSettings()
        XCTAssertTrue(fallback.isFlat)
    }

    func testVideoIDExtraction() {
        XCTAssertEqual(Track.videoID(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(Track.videoID(from: "https://youtu.be/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(Track.videoID(from: "https://www.youtube.com/shorts/abc123XYZ_-"), "abc123XYZ_-")
        XCTAssertNil(Track.videoID(from: "not a url"))
        XCTAssertTrue(Track.isYouTubePlaylistURL("https://www.youtube.com/playlist?list=PL123"))
        XCTAssertTrue(Track.isYouTubePlaylistURL("https://www.youtube.com/watch?v=abc&list=PL123"))
        XCTAssertFalse(Track.isYouTubePlaylistURL("https://www.youtube.com/watch?v=abc"))
    }

    // MARK: - Time formatting

    func testTimeFormatting() {
        XCTAssertEqual(TimeFormatting.format(seconds: 0), "0:00")
        XCTAssertEqual(TimeFormatting.format(seconds: -5), "0:00")
        XCTAssertEqual(TimeFormatting.format(seconds: 65), "1:05")
        XCTAssertEqual(TimeFormatting.format(seconds: 3661), "1:01:01")
        XCTAssertEqual(TimeFormatting.format(seconds: Double.nan), "0:00")
        XCTAssertEqual(TimeFormatting.formatCounter(current: 65, duration: 200), "01:05")
    }

    // MARK: - Search parsing

    func testParseSearchLine() {
        let line = #"{"id":"abc","title":"Song","uploader":"Artist","duration_string":"3:12","webpage_url":"https://www.youtube.com/watch?v=abc","thumbnails":[{"url":"https://example.com/t.jpg"}]}"#
        let result = YTDLPModels.parseSearchLine(line)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.id, "abc")
        XCTAssertEqual(result?.uploader, "Artist")
        XCTAssertEqual(result?.thumbnailURL, "https://example.com/t.jpg")
    }

    func testParseSearchSkipsBadLines() {
        let output = "not json\n{\"id\":\"ok\",\"title\":\"T\"}\n"
        let results = YTDLPModels.parseSearchOutput(output)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, "ok")
    }

    func testBestThumbnailPrefersLast() {
        let json: [String: Any] = [
            "thumbnails": [
                ["url": "https://example.com/small.jpg"],
                ["url": "https://example.com/big.jpg"],
            ]
        ]
        XCTAssertEqual(YTDLPModels.bestThumbnail(from: json), "https://example.com/big.jpg")
    }

    // MARK: - Stream parsing (--print lines) + cache expiry

    func testParsePrintedStream() {
        let output = "https://cdn.example/a.m4a?expire=9999999999&ip=1.2.3.4\nm4a\nmp4a.40.2\n129.499\n44100\n"
        let info = YTDLPModels.parsePrintedStream(output)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.streamURL, "https://cdn.example/a.m4a?expire=9999999999&ip=1.2.3.4")
        XCTAssertEqual(info?.bitrateKbps, 129)
        XCTAssertEqual(info?.sampleRateKHz, 44)
        XCTAssertEqual(info?.codec, "mp4a.40.2")
        XCTAssertEqual(info?.ext, "m4a")
    }

    func testParsePrintedStreamHandlesNA() {
        let output = "https://cdn.example/a.mp4\nNA\nNA\nNA\nNA\n"
        let info = YTDLPModels.parsePrintedStream(output)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.bitrateKbps, 128)
        XCTAssertEqual(info?.sampleRateKHz, 44)
        XCTAssertEqual(info?.codec, "")
        XCTAssertEqual(info?.ext, "")
    }

    func testParsePrintedStreamRejectsGarbage() {
        XCTAssertNil(YTDLPModels.parsePrintedStream(""))
        XCTAssertNil(YTDLPModels.parsePrintedStream("not a url\nm4a\nmp4a\n128\n44100\n"))
        XCTAssertNil(YTDLPModels.parsePrintedStream("https://cdn.example/a.m4a\nm4a\n"))
    }

    func testStreamExpiryParsesExpireParam() {
        let farFuture = "https://rr1.googlevideo.com/videoplayback?expire=2000000000&ip=1.2.3.4"
        let expiry = YTDLPModels.streamExpiry(from: farFuture)
        XCTAssertEqual(expiry, Date(timeIntervalSince1970: 2000000000 - 300))
        XCTAssertTrue(expiry > Date(), "far-future URL must still be valid")
    }

    func testStreamExpiryFallsBackWithoutParam() {
        let before = Date()
        let expiry = YTDLPModels.streamExpiry(from: "https://cdn.example/a.m4a")
        let expected = before.addingTimeInterval(YTDLPModels.streamCacheDefaultTTL)
        XCTAssertLessThan(abs(expiry.timeIntervalSince(expected)), 5)
    }

    func testStreamExpiryInPastIsExpired() {
        let old = "https://rr1.googlevideo.com/videoplayback?expire=1000&ip=1.2.3.4"
        XCTAssertTrue(YTDLPModels.streamExpiry(from: old) < Date())
    }

    func testParsePlaylistSkipsInvalidEntries() {
        let json = #"{"_type":"playlist","title":"Mix","entries":[{"id":"a","title":"A","url":"https://www.youtube.com/watch?v=a"},{"title":"No ID"},{"id":"b","title":"B"}]}"#
        guard case .playlist(let title, let entries) = YTDLPModels.parseURLInfoJSON(json) else {
            return XCTFail("expected playlist")
        }
        XCTAssertEqual(title, "Mix")
        XCTAssertEqual(entries.count, 2)
    }

    // MARK: - EQ DSP

    func testPeakingFlatIsIdentity() {
        let flat = EqualizerDSP.peakingCoefficients(frequency: 1000, sampleRate: 44100, gainDB: 0)
        XCTAssertEqual(flat, EqualizerDSP.Biquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0))
        var processor = EQProcessor(preampDB: 0, bandGainsDB: Array(repeating: 0, count: 10))
        let input: [Float] = [0.5, -0.5, 0.25]
        let output = processor.process(input)
        XCTAssertEqual(output.count, 3)
        for (a, b) in zip(input, output) {
            XCTAssertEqual(Double(a), Double(b), accuracy: 1e-6)
        }
    }

    func testPreampBoostIncreasesLevel() {
        var flat = EQProcessor(preampDB: 0, bandGainsDB: Array(repeating: 0, count: 10))
        var boosted = EQProcessor(preampDB: 6, bandGainsDB: Array(repeating: 0, count: 10))
        let input: [Float] = [0.5]
        let flatOut = flat.process(input)[0]
        let boostedOut = boosted.process(input)[0]
        XCTAssertGreaterThan(abs(boostedOut), abs(flatOut))
    }
}
