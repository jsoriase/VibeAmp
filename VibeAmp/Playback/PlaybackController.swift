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
    private var bufferingObserver: NSKeyValueObservation?
    private var durationObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var tapContext: EQTapContext?
    private var currentAudioTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    private var prefetchTask: Task<Void, Never>?
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
        if isPlaying { pause() } else { play() }
    }

    func play() {
        ensurePlayer()
        guard let player else { return }
        if player.currentItem == nil {
            // Nothing loaded: try to load the queue's current track.
            if let track = queue.currentTrack {
                load(track)
            } else {
                statusMessage = "Queue is empty — search for something"
            }
            return
        }
        player.play()
        isPlaying = true
        if case .failed = status {
            status = .playing
        } else if status == .idle || status == .stopped {
            status = .playing
        }
        statusMessage = "Playing"
        nowPlaying?.update()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        if status == .playing { status = .paused }
        statusMessage = "Paused"
        nowPlaying?.update()
    }

    func stop() {
        player?.pause()
        player?.seek(to: .zero)
        currentTime = 0
        isPlaying = false
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
        loadGeneration += 1
        let generation = loadGeneration
        didRetryCurrent = false
        prefetchTask?.cancel()
        prefetchTask = nil
        currentTrack = track
        currentTime = 0
        duration = track.durationSeconds ?? 0
        bitrateKbps = 0
        sampleRateKHz = 0
        status = .loading
        isBuffering = true
        statusMessage = "Resolving stream…"
        log?.info("Loading: \(track.title)")
        nowPlaying?.update()

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let wasCached = await self.youtube.cachedStream(for: track.webpageURL) != nil
                let stream = try await self.youtube.stream(urlString: track.webpageURL)
                // Stale load guard: ignore if the user moved on.
                guard generation == self.loadGeneration else { return }
                self.bitrateKbps = stream.bitrateKbps
                self.sampleRateKHz = stream.sampleRateKHz
                if wasCached {
                    self.log?.info("Stream cache hit (\(stream.ext.isEmpty ? "audio" : stream.ext))")
                } else {
                    self.log?.info("Stream resolved (\(stream.ext.isEmpty ? "audio" : stream.ext), \(stream.bitrateKbps) kbps)")
                }
                self.statusMessage = "Loading audio…"
                await self.playStream(urlString: stream.streamURL, track: track, generation: generation)
            } catch {
                guard generation == self.loadGeneration else { return }
                // One fresh retry for transient/expired-URL failures is handled
                // at the AVPlayer level; here a resolve failure is terminal.
                self.status = .failed(error.localizedDescription)
                self.statusMessage = "Playback error: \(error.localizedDescription)"
                self.isBuffering = false
                self.log?.error("Error fetching stream URL: \(error.localizedDescription)")
                self.nowPlaying?.update()
            }
        }
    }

    private func playStream(urlString: String, track: Track, generation: Int) async {
        guard generation == loadGeneration else { return }
        guard let url = URL(string: urlString) else {
            status = .failed("Invalid stream URL")
            statusMessage = "Playback error: invalid stream URL"
            isBuffering = false
            return
        }
        teardownItemObservers()
        currentAudioTrackID = kCMPersistentTrackID_Invalid

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)

        playerItem = item
        observe(item: item, track: track)
        ensurePlayer()
        player?.replaceCurrentItem(with: item)
        player?.volume = Float(volume)
        player?.play()
        isPlaying = true
        status = .playing
        statusMessage = "Playing"
        log?.info("Playback started: \(track.title)")
        nowPlaying?.update()
        prefetchNext()

        // EQ tap attaches as soon as the audio track ID is known, without
        // blocking first sound: resolving tracks needs its own round trip to
        // the CDN, so awaiting it here would delay playback audibly.
        Task { @MainActor [weak self] in
            await self?.attachEQ(to: item, asset: asset, generation: generation)
        }
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

    /// Resolves the next track's stream while the current one plays, so
    /// Next and auto-advance start instantly. Best-effort and keyed by URL,
    /// so a superseded prefetch can never corrupt playback. Only one runs
    /// at a time; a track change cancels the stale one (which also frees
    /// the service actor for the newly demanded resolve).
    private func prefetchNext() {
        prefetchTask?.cancel()
        guard let next = queue.peek(1) else {
            prefetchTask = nil
            return
        }
        prefetchTask = Task { [weak self] in
            await self?.youtube.prefetch(urlString: next.webpageURL)
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

    private func observe(item: AVPlayerItem, track: Track) {
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                if item.status == .failed {
                    self.handleItemFailed(track: track, error: item.error)
                }
            }
        }
        bufferingObserver = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                self?.isBuffering = item.isPlaybackBufferEmpty
                if item.isPlaybackBufferEmpty {
                    self?.log?.info("Buffering…")
                }
            }
        }
        // Keep duration fresh for the seek bar + menu bar.
        durationObserver = item.observe(\.duration, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                let seconds = item.duration.seconds
                if seconds.isFinite, seconds > 0 {
                    self?.duration = seconds
                    self?.nowPlaying?.update()
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleEnded() }
        }
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                if let track = self?.currentTrack {
                    self?.handleItemFailed(track: track, error: error)
                }
            }
        }
    }

    private func teardownItemObservers() {
        statusObserver?.invalidate()
        bufferingObserver?.invalidate()
        durationObserver?.invalidate()
        statusObserver = nil
        bufferingObserver = nil
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
                guard let self else { return }
                let seconds = time.seconds
                if seconds.isFinite, seconds >= 0 {
                    self.currentTime = seconds
                }
                if let item = self.player?.currentItem {
                    let dur = item.duration.seconds
                    if dur.isFinite, dur > 0 { self.duration = dur }
                    self.isBuffering = item.isPlaybackBufferEmpty && self.isPlaying
                }
                // Throttle Now Playing elapsed updates to whole seconds.
                self.nowPlaying?.updateIfSecondChanged(elapsed: self.currentTime, duration: self.duration)
            }
        }
    }

    private func handleEnded() {
        log?.info("Track ended — advancing")
        if let track = queue.step(1) {
            load(track)
        } else {
            isPlaying = false
            status = .stopped
            statusMessage = "Stopped"
            nowPlaying?.update()
        }
    }

    private func handleItemFailed(track: Track, error: Error?) {
        // One fresh stream resolution before giving up (covers expired CDN URLs).
        if !didRetryCurrent {
            didRetryCurrent = true
            log?.warning("Playback failed (\(error?.localizedDescription ?? "unknown")) — retrying with a fresh stream URL")
            loadGeneration += 1
            let generation = loadGeneration
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    // Bypass the cache: the cached URL is exactly what failed.
                    let stream = try await self.youtube.resolveFreshStream(urlString: track.webpageURL)
                    guard generation == self.loadGeneration else { return }
                    self.bitrateKbps = stream.bitrateKbps
                    self.sampleRateKHz = stream.sampleRateKHz
                    await self.playStream(urlString: stream.streamURL, track: track, generation: generation)
                } catch {
                    guard generation == self.loadGeneration else { return }
                    self.status = .failed(error.localizedDescription)
                    self.statusMessage = "Playback error: \(error.localizedDescription)"
                    self.isPlaying = false
                    self.isBuffering = false
                    self.log?.error("Playback failed: \(error.localizedDescription)")
                    self.nowPlaying?.update()
                }
            }
            return
        }
        status = .failed(error?.localizedDescription ?? "Playback failed")
        statusMessage = "Playback error: \(error?.localizedDescription ?? "unknown error")"
        isPlaying = false
        isBuffering = false
        log?.error("Playback failed: \(error?.localizedDescription ?? "unknown error")")
        nowPlaying?.update()
    }

    deinit {
        // Note: @MainActor teardown; observers removed on next load or dealloc.
        // timeObserver removal requires the player; kept alive with controller.
    }
}
