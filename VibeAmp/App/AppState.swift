import Foundation
import Observation

/// Composition root: ONE shared application state.
/// Every window observes the same native Swift objects — no IPC.
/// Individual stores are injected into SwiftUI environments by type so views
/// subscribe directly; AppState owns lifecycle + startup + persistence wiring.
@MainActor
@Observable
final class AppState {
    let store: StateStore
    let queue: QueueStore
    let eq: EQStore
    let log: AppLog
    let playback: PlaybackController
    let ytdlp: YTDLPManager
    let windows: WindowManager
    let youtube: YouTubeService

    init() {
        store = StateStore()
        store.load()
        queue = QueueStore()
        eq = EQStore()
        log = AppLog()
        playback = PlaybackController()
        ytdlp = YTDLPManager()
        windows = WindowManager()
        youtube = YouTubeService()
    }

    /// Restores persisted volume / EQ / queue before windows appear.
    func restorePersistedState() {
        let volume = store.getDouble(key: "volume", fallback: 1.0)
        let eqDict = store.get([String: Double].self, key: "eq", fallback: [:])
        let eqSettings: EQSettings = eqDict.isEmpty ? EQSettings() : EQSettings(fromLegacy: eqDict)
        // Support the modern shape too (preamp + bands nested).
        eq.settings = eqSettings

        if let persisted = persistedQueue() {
            queue.restore(persisted)
        }

        windows.configure(stateStore: store, log: log)
        playback.configure(
            queue: queue,
            eq: eq,
            log: log,
            youtube: youtube,
            stateStore: store,
            volume: volume
        )
        log.info("VibeAmp starting — restoring previous session")
    }

    private func persistedQueue() -> QueueStore.Persisted? {
        let entries: [Track] = store.get([Track].self, key: "queueEntries", fallback: [])
        if !entries.isEmpty {
            let index: Int = store.get(Int.self, key: "queueIndex", fallback: -1)
            return QueueStore.Persisted(entries: entries, currentIndex: index)
        }
        // Native nested blob { entries, currentIndex } under "queue" (modern Track shape).
        struct NativeQueue: Codable {
            var entries: [Track] = []
            var currentIndex: Int = -1
        }
        let native: NativeQueue = store.get(NativeQueue.self, key: "queue", fallback: NativeQueue())
        // Distinguish native vs Electron shape: native entries decode only when
        // webpageURL is present; Electron entries use url/thumbnail/duration.
        // If native decode yields entries, prefer them.
        if !native.entries.isEmpty && !native.entries.allSatisfy({ $0.webpageURL.isEmpty }) {
            return QueueStore.Persisted(entries: native.entries, currentIndex: native.currentIndex)
        }
        // Electron migration: { entries: [{id,title,url,thumbnail,duration,uploader}], currentIndex }.
        struct ElectronEntry: Codable {
            var id: String?
            var title: String?
            var url: String?
            var thumbnail: String?
            var duration: String?
            var uploader: String?
        }
        struct ElectronQueue: Codable {
            var entries: [ElectronEntry] = []
            var currentIndex: Int = -1
        }
        let electron: ElectronQueue = store.get(ElectronQueue.self, key: "queue", fallback: ElectronQueue())
        if !electron.entries.isEmpty {
            let tracks: [Track] = electron.entries.compactMap { entry in
                guard let id = entry.id, !id.isEmpty else { return nil }
                let url = entry.url ?? "https://www.youtube.com/watch?v=\(id)"
                guard !url.isEmpty else { return nil }
                return Track(
                    id: id,
                    title: entry.title ?? "Untitled",
                    uploader: entry.uploader ?? "",
                    durationString: entry.duration ?? "",
                    webpageURL: url,
                    thumbnailURL: entry.thumbnail ?? ""
                )
            }
            if !tracks.isEmpty {
                let index = (electron.currentIndex >= 0 && electron.currentIndex < tracks.count)
                    ? electron.currentIndex : -1
                return QueueStore.Persisted(entries: tracks, currentIndex: index)
            }
        }
        return nil
    }

    /// Persists queue + EQ (volume persists live from the playback controller).
    /// Note: native queue lives under queueEntries/queueIndex so the legacy
    /// Electron "queue" blob is preserved for migration (see persistedQueue).
    func persistEphemeral() {
        let snapshot = queue.snapshot()
        store.set(key: "queueEntries", value: snapshot.entries)
        store.set(key: "queueIndex", value: snapshot.currentIndex)
        store.set(key: "eq", value: eq.settings.legacyDictionary)
        // Modern shape as well for forward compatibility.
        store.set(key: "eqSettings", value: eq.settings)
        windows.saveLayout()
    }

    func persistNow() {
        persistEphemeral()
        store.flush()
    }

    // MARK: - Queue actions shared by Search / Playlist / MenuBar

    func addAndPlay(_ track: Track) {
        queue.addAndPlay(track)
        persistEphemeral()
        playback.load(track)
    }

    func replaceAndPlay(_ tracks: [Track], title: String? = nil) {
        queue.replaceAndPlay(tracks)
        persistEphemeral()
        if let title { log.info("Playlist imported: \(title) (\(tracks.count) tracks)") }
        if let current = queue.currentTrack {
            playback.load(current)
        }
    }

    func playIndex(_ index: Int) {
        if let track = queue.playIndex(index) {
            persistEphemeral()
            playback.load(track)
        }
    }

    func step(_ delta: Int) {
        if let track = queue.step(delta) {
            persistEphemeral()
            playback.load(track)
        }
    }

    // MARK: - Startup

    func startup() async {
        restorePersistedState()
        await ytdlp.ensure(log: log)
        await youtube.configure(binaryURL: ytdlp.binaryURL)
        if case .failed(let message) = ytdlp.status {
            log.error("yt-dlp unavailable: \(message)")
        }
    }
}
