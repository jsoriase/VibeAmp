import AVFoundation
import Foundation
import Observation
import MediaPlayer

/// Central playback engine. Exactly one exists; every window observes it.
/// Uses AVPlayer for stable streaming of yt-dlp-resolved CDN URLs, with a
/// genuine 10-band EQ applied via MTAudioProcessingTap (see EqualizerTap).
@MainActor
@Observable
final class PlaybackController {
    enum Status: Equatable {
        case idle
        case loading
        case playing
        case paused
        case stopped
        case failed(String)
    }

    // MARK: - Observed state

    var status: Status = .idle
    var currentTrack: Track?
    var currentTime: Double = 0
    var duration: Double = 0
    var volume: Double = 1.0
    var isBuffering: Bool = false
    var bitrateKbps: Int = 0
    var sampleRateKHz: Int = 0
    var statusMessage: String = "Ready to stream..."
    var isPlaying: Bool = false
    var isEQAvailable = true

    // MARK: - Collaborators (injected)

    var queue: QueueStore!
    var eq: EQStore!
    var log: AppLog!
    var youtube: YouTubeService!
    var stateStore: StateStore?
    var nowPlaying: NowPlayingController?

    // MARK: - AVFoundation

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var playbackObserver: NSKeyValueObservation?
    private var loadTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var metadataDuration: Double?
    private var indexedDuration: Double?
    private var watchdog: Task<Void, Never>?
    private var segmentedAudio: SegmentedAudio?
    private var wantsPlayback = false
    private var waitStarted: Date?
    private var lastProgressTime: Double = 0
    var playbackTimeout: TimeInterval = 45
    private var durationObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var tapContext: EQTapContext?
    private var currentAudioTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    private var prefetchTargetKey: String?
    private var loadGeneration = 0
    private var didRetryCurrent = false
    private var lastPersistedVolume: Double = -1

    init() {}

    func configure(
        queue: QueueStore,
        eq: EQStore,
        log: AppLog,
        youtube: YouTubeService,
        stateStore: StateStore?,
        volume: Double
    ) {
        self.queue = queue
        self.eq = eq
        self.log = log
        self.youtube = youtube
        self.stateStore = stateStore
        self.volume = min(1, max(0, volume))
        self.lastPersistedVolume = self.volume
        ensurePlayer()
        nowPlaying = NowPlayingController()
        nowPlaying?.configure(controller: self)
    }

    private func ensurePlayer() {
        if player == nil {
            player = AVPlayer()
            player?.volume = Float(volume)
            addPeriodicObserver()
        }
    }

    // MARK: - Transport

    func toggle() {
        if wantsPlayback { pause() } else { play() }
    }

    func play() {
        ensurePlayer()
        guard let player else { return }
        if status == .loading && wantsPlayback { return }
        if player.currentItem == nil || player.currentItem?.status == .failed {
            if let track = currentTrack ?? queue.currentTrack { load(track) }
            else { statusMessage = "Queue is empty — search for something" }
            return
        }
        wantsPlayback = true
        startWatchdog(generation: loadGeneration)
        player.play()
        syncPlaybackState()
    }

    func pause() {
        wantsPlayback = false
        // A resolve has no item to pause. Invalidate it so it cannot autoplay later.
        if playerItem == nil { loadGeneration += 1; loadTask?.cancel() }
        watchdog?.cancel()
        player?.pause()
        isPlaying = false
        isBuffering = false
        status = .paused
        statusMessage = "Paused"
        nowPlaying?.update()
    }

    func stop() {
        loadGeneration += 1
        loadTask?.cancel()
        durationTask?.cancel()
        watchdog?.cancel()
        wantsPlayback = false
        teardownItemObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playerItem = nil
        segmentedAudio = nil
        currentTime = 0
        isPlaying = false
        isBuffering = false
        status = .stopped
        statusMessage = "Stopped"
        nowPlaying?.update()
    }

    func next() {
        if let track = queue.step(1) {
            load(track)
        }
    }

    func previous() {
        if let track = queue.step(-1) {
            load(track)
        }
    }

    func playIndex(_ index: Int) {
        if let track = queue.playIndex(index) {
            load(track)
        }
    }

    func seek(fraction: Double) {
        guard let player, duration > 0 else { return }
        let clamped = min(1, max(0, fraction))
        let target = CMTime(seconds: clamped * duration, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.nowPlaying?.update(elapsedOverride: clamped * (self?.duration ?? 0)) }
        }
    }

    func seekTo(seconds: Double) {
        guard duration > 0 else { return }
        seek(fraction: seconds / duration)
    }

    func setVolume(_ value: Double) {
        let clamped = min(1, max(0, value))
        volume = clamped
        player?.volume = Float(clamped)
        if abs(clamped - lastPersistedVolume) > 0.005 {
            lastPersistedVolume = clamped
            stateStore?.setDouble(key: "volume", value: clamped)
        }
    }

    // MARK: - Loading

    /// Loads a track: resolves a fresh AVFoundation-friendly stream URL and plays.
    /// Stream URLs expire, so they are never persisted — only the YouTube identity is.
    func load(_ track: Track) {
        didRetryCurrent = false
        prefetchTargetKey = nil
        currentTrack = track
        currentTime = 0
        duration = PlaybackDuration.seconds(reported: track.durationSeconds ?? 0)
        bitrateKbps = 0
        sampleRateKHz = 0
        beginLoad(track, fresh: false)
    }

    private func beginLoad(_ track: Track, fresh: Bool) {
        loadGeneration += 1
        let generation = loadGeneration
        loadTask?.cancel()
        durationTask?.cancel()
        metadataDuration = track.durationSeconds
        indexedDuration = nil
        teardownItemObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playerItem = nil
        segmentedAudio = nil
        tapContext = nil
        currentAudioTrackID = kCMPersistentTrackID_Invalid
        wantsPlayback = true
        isPlaying = false
        isBuffering = true
        isEQAvailable = true
        status = .loading
        statusMessage = fresh ? "Refreshing stream…" : "Resolving stream…"
        log?.info("Loading: \(track.title)")
        startWatchdog(generation: generation)
        nowPlaying?.update()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let stream = try await fresh
                    ? self.youtube.resolveFreshStream(urlString: track.webpageURL)
                    : self.youtube.stream(urlString: track.webpageURL)
                try Task.checkCancellation()
                guard generation == self.loadGeneration else { return }
                self.bitrateKbps = stream.bitrateKbps
                self.sampleRateKHz = stream.sampleRateKHz
                self.metadataDuration = stream.durationSeconds ?? track.durationSeconds
                try await self.playStream(stream, track: track, generation: generation)
            } catch {
                guard generation == self.loadGeneration, !Task.isCancelled else { return }
                self.finishFailure(error)
            }
        }
    }

    private func playStream(_ stream: YTDLPModels.StreamInfo, track: Track, generation: Int) async throws {
        guard let url = URL(string: stream.streamURL), ["https", "http"].contains(url.scheme) else {
            throw URLError(.badURL)
        }
        var playbackURL = url
        var adapter: SegmentedAudio?
        var index: AudioSegmentIndex?
        let hasMP4Index = stream.ext == "m4a" && !url.path.contains("m3u8")
        // Long fragmented MP4 files can make AVPlayer scan thousands of fragments
        // before starting. Songs retain the file playback path and its EQ tap.
        if (metadataDuration ?? 0) >= 15 * 60, hasMP4Index {
            statusMessage = "Preparing audio segments…"
            do {
                index = try await AudioSegmentIndex.load(mediaURL: url)
                if let index {
                    let segmented = try await SegmentedAudio.serve(playlist: index.playlist(mediaURL: url))
                    adapter = segmented
                    playbackURL = segmented.url
                } else { log?.warning("No supported segment index; using direct audio with a playback timeout") }
            } catch {
                try Task.checkCancellation()
                log?.warning("Could not prepare segments: \(error.localizedDescription); using direct audio")
            }
        }
        try Task.checkCancellation()
        guard generation == loadGeneration else { return }
        segmentedAudio = adapter
        indexedDuration = index?.duration
        isEQAvailable = adapter == nil && !url.path.contains("m3u8")
        let asset = AVURLAsset(url: playbackURL)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 10
        playerItem = item
        updateDuration(for: item)
        ensurePlayer()
        observe(item: item, track: track)
        player?.replaceCurrentItem(with: item)
        player?.volume = Float(volume)
        statusMessage = "Loading audio…"
        player?.play()
        syncPlaybackState()
        if hasMP4Index, (metadataDuration ?? 0) < 15 * 60 {
            // Correct short files without delaying playback or disabling EQ.
            durationTask = Task { @MainActor [weak self] in
                do {
                    guard let index = try await AudioSegmentIndex.load(mediaURL: url) else { return }
                    try Task.checkCancellation()
                    guard let self, generation == self.loadGeneration, self.playerItem === item else { return }
                    self.indexedDuration = index.duration
                    self.updateDuration(for: item)
                    self.nowPlaying?.update()
                } catch {
                    guard let self, !Task.isCancelled, generation == self.loadGeneration else { return }
                    self.log?.warning("Could not read audio duration; using stream metadata: \(error.localizedDescription)")
                }
            }
        }
        if adapter != nil { log?.info("Segmented playback ready — audio is fetched directly from the CDN") }
        if isEQAvailable {
            Task { @MainActor [weak self] in
                await self?.attachEQ(to: item, asset: asset, generation: generation)
            }
        } else {
            log?.warning("EQ unavailable for segmented audio on this macOS playback engine")
        }
    }

    private func syncPlaybackState() {
        guard wantsPlayback, let player, let item = playerItem,
              player.currentItem === item else { return }
        let playing = player.timeControlStatus == .playing
        let changed = isPlaying != playing
        isPlaying = playing
        isBuffering = !playing
        status = playing ? .playing : .loading
        statusMessage = playing ? "Playing" : "Buffering audio…"
        if playing {
            waitStarted = nil
            if changed {
                log?.info("Playback started: \(currentTrack?.title ?? "audio")")
                refreshPrefetch()
            }
        }
        nowPlaying?.update()
    }

    /// Covers URL resolution, startup, and later stalls. Progress resets the
    /// deadline; pausing/stopping cancels it. Stale loads cannot trigger a retry.
    private func startWatchdog(generation: Int) {
        watchdog?.cancel()
        waitStarted = Date()
        lastProgressTime = player?.currentTime().seconds ?? 0
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.loadGeneration == generation, self.wantsPlayback else { return }
                let time = self.player?.currentTime().seconds ?? 0
                if time.isFinite, time != self.lastProgressTime, self.player?.timeControlStatus == .playing {
                    self.waitStarted = nil
                } else if self.waitStarted == nil {
                    self.waitStarted = Date()
                }
                self.lastProgressTime = time
                if let started = self.waitStarted, Date().timeIntervalSince(started) >= self.playbackTimeout {
                    let error = NSError(domain: "VibeAmp", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        "Audio did not respond within \(Int(self.playbackTimeout)) seconds"])
                    if let track = self.currentTrack { self.handleItemFailed(track: track, error: error) }
                    return
                }
            }
        }
    }

    private func finishFailure(_ error: Error) {
        loadGeneration += 1
        loadTask?.cancel()
        durationTask?.cancel()
        watchdog?.cancel()
        wantsPlayback = false
        teardownItemObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playerItem = nil
        segmentedAudio = nil
        isPlaying = false
        isBuffering = false
        status = .failed(error.localizedDescription)
        statusMessage = "Playback error: \(error.localizedDescription)"
        log?.error(statusMessage)
        nowPlaying?.update()
    }

    /// Resolves the audio track ID and attaches the genuine EQ tap.
    /// Uses the latest slider values at attach time, so EQ moves made while
    /// tracks were still loading are honoured.
    private func attachEQ(to item: AVPlayerItem, asset: AVURLAsset, generation: Int) async {
        var trackID = kCMPersistentTrackID_Invalid
        do {
            if let first = try await asset.loadTracks(withMediaType: .audio).first {
                trackID = first.trackID
            }
        } catch {
            log?.warning("Could not load audio tracks — playing without EQ: \(error.localizedDescription)")
            return
        }
        guard generation == loadGeneration, playerItem === item else { return }
        currentAudioTrackID = trackID
        guard trackID != kCMPersistentTrackID_Invalid else { return }
        var context: EQTapContext?
        if let mix = EqualizerTap.audioMix(
            audioTrackID: trackID,
            preampDB: eq.settings.preamp,
            bandGainsDB: eq.settings.orderedBandGains,
            contextOut: &context
        ) {
            guard generation == loadGeneration, playerItem === item else { return }
            item.audioMix = mix
            tapContext = context
        } else {
            log?.warning("EQ tap unavailable — playing without EQ for this track")
        }
    }

    /// Re-evaluate after starting playback or editing the queue. A resolution
    /// already in progress remains service-owned, ready for a subsequent Next.
    func refreshPrefetch() {
        guard let queue, let youtube, status == .playing || status == .paused,
              let currentTrack, let queuedTrack = queue.currentTrack,
              YouTubeService.streamKey(for: currentTrack.webpageURL) == YouTubeService.streamKey(for: queuedTrack.webpageURL)
        else { return }
        guard let next = queue.peek(1) else {
            if prefetchTargetKey != "<none>" {
                prefetchTargetKey = "<none>"
                log?.info("[PREFETCH] Skipped: no next track in queue")
            }
            return
        }
        let key = YouTubeService.streamKey(for: next.webpageURL)
        guard prefetchTargetKey != key else { return }
        prefetchTargetKey = key
        log?.info("[PREFETCH] Next track: \(next.title)")
        Task {
            await youtube.prefetch(urlString: next.webpageURL)
        }
    }

    /// Re-attaches the EQ tap with fresh coefficients (e.g. after slider moves).
    /// AVAudioMix is immutable once attached, so we build a new mix and assign it.
    func refreshEQ() {
        guard let item = playerItem else { return }
        // If tracks are still resolving, the pending attach picks up the
        // latest slider values on its own — nothing to rebuild yet.
        guard currentAudioTrackID != kCMPersistentTrackID_Invalid else { return }
        var context: EQTapContext?
        if let mix = EqualizerTap.audioMix(
            audioTrackID: currentAudioTrackID,
            preampDB: eq.settings.preamp,
            bandGainsDB: eq.settings.orderedBandGains,
            contextOut: &context
        ) {
            item.audioMix = mix
            tapContext = context
        }
        // Live-update the running tap without rebuilding when possible.
        // (Rebuilding the mix is cheap and glitch-free enough for slider drags
        // at this scale; the tap context update below keeps audio-thread state
        // coherent if we ever switch to in-place updates.)
    }

    // MARK: - Observers

    private func updateDuration(for item: AVPlayerItem) {
        duration = PlaybackDuration.apply(to: item, indexed: indexedDuration, metadata: metadataDuration)
    }

    private func observe(item: AVPlayerItem, track: Track) {
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.playerItem === item else { return }
                if item.status == .failed {
                    self.handleItemFailed(track: track, error: item.error)
                }
            }
        }
        playbackObserver = player?.observe(\.timeControlStatus, options: [.new]) { [weak self, weak item] _, _ in
            Task { @MainActor in
                guard let self, let item, self.playerItem === item else { return }
                self.syncPlaybackState()
            }
        }
        // Keep duration fresh for the seek bar + menu bar.
        durationObserver = item.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.playerItem === item else { return }
                self.updateDuration(for: item)
                self.nowPlaying?.update()
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.playerItem === item else { return }
                self.handleEnded()
            }
        }
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self, self.playerItem === item else { return }
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                if let track = self.currentTrack {
                    self.handleItemFailed(track: track, error: error)
                }
            }
        }
    }

    private func teardownItemObservers() {
        statusObserver?.invalidate()
        playbackObserver?.invalidate()
        durationObserver?.invalidate()
        statusObserver = nil
        playbackObserver = nil
        durationObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        endObserver = nil
        failObserver = nil
    }

    private func addPeriodicObserver() {
        guard let player, timeObserver == nil else { return }
        // ~4 Hz is plenty for an LCD time readout; avoids needless UI churn.
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, let activeItem = self.player?.currentItem, activeItem === self.playerItem else { return }
                let seconds = time.seconds
                if seconds.isFinite, seconds >= 0 {
                    self.currentTime = seconds
                }
                self.updateDuration(for: activeItem)
                // Throttle Now Playing elapsed updates to whole seconds.
                self.nowPlaying?.updateIfSecondChanged(elapsed: self.currentTime, duration: self.duration)
            }
        }
    }

    private func handleEnded() {
        guard wantsPlayback else { return }
        log?.info("Track ended — advancing")
        if let track = queue.step(1) {
            load(track)
        } else {
            wantsPlayback = false
            watchdog?.cancel()
            isPlaying = false
            isBuffering = false
            status = .stopped
            statusMessage = "Stopped"
            nowPlaying?.update()
        }
    }

    private func handleItemFailed(track: Track, error: Error?) {
        guard wantsPlayback else { return }
        if !didRetryCurrent {
            didRetryCurrent = true
            log?.warning("Playback stalled or failed — retrying once with a fresh stream URL")
            beginLoad(track, fresh: true)
        } else {
            finishFailure(error ?? URLError(.cannotDecodeContentData))
        }
    }
}

/// Use the fragment timeline when available; metadata bounds malformed container
/// durations otherwise. yt-dlp metadata can be rounded to whole seconds, so allow
/// one second of encoder padding rather than cutting the final audio samples.
enum PlaybackDuration {
    @MainActor
    static func apply(to item: AVPlayerItem, indexed: Double? = nil, metadata: Double? = nil) -> Double {
        let duration = seconds(indexed: indexed, metadata: metadata, reported: item.duration.seconds)
        // Bound the transport as well as the UI: the normal end notification
        // must advance the queue before the malformed container's silent tail.
        // Without an independent duration, retain AVPlayer's natural end (live
        // streams in particular must not get a fixed playback boundary).
        let hasKnownEnd = [indexed, metadata].contains { value in
            guard let value else { return false }
            return value.isFinite && value > 0
        }
        let end = hasKnownEnd ? CMTime(seconds: duration, preferredTimescale: 1_000_000) : .invalid
        if CMTimeCompare(item.forwardPlaybackEndTime, end) != 0 {
            item.forwardPlaybackEndTime = end
        }
        return duration
    }

    static func seconds(indexed: Double? = nil, metadata: Double? = nil, reported: Double = .nan) -> Double {
        if let indexed, indexed.isFinite, indexed > 0 { return indexed }
        if let metadata, metadata.isFinite, metadata > 0 {
            if reported.isFinite, reported > 0 { return min(reported, metadata + 1) }
            return metadata + 1
        }
        return reported.isFinite && reported > 0 ? reported : 0
    }
}
