import Foundation
import MediaPlayer
import AppKit

/// System media integration: Control Center / Now Playing / media keys.
/// Never breaks core playback — all calls are defensive and throttled.
@MainActor
final class NowPlayingController {
    private weak var controller: PlaybackController?
    private var lastPublishedSecond: Int = -1
    private var lastTitle: String?

    func configure(controller: PlaybackController) {
        self.controller = controller
        setupRemoteCommands()
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.controller?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.controller?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.controller?.toggle() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.controller?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.controller?.previous() }
            return .success
        }
    }

    func update(elapsedOverride: Double? = nil) {
        guard let controller else { return }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = controller.currentTrack?.title ?? "VibeAmp"
        info[MPMediaItemPropertyArtist] = controller.currentTrack?.uploader ?? ""
        info[MPMediaItemPropertyPlaybackDuration] = controller.duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedOverride ?? controller.currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = controller.isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        // Artwork loads async and must never block playback.
        if let urlString = controller.currentTrack?.thumbnailURL,
           !urlString.isEmpty,
           urlString != lastTitle || lastPublishedSecond == -1 {
            lastTitle = urlString
            Task.detached { [urlString] in
                guard let url = URL(string: urlString),
                      let data = try? Data(contentsOf: url),
                      let image = NSImage(data: data)
                else { return }
                await MainActor.run {
                    var current = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    current[MPMediaItemPropertyArtwork] = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = current
                }
            }
        }
        lastPublishedSecond = Int((elapsedOverride ?? controller.currentTime).rounded())
    }

    /// Called ~4 Hz from the time observer; only publishes when the second flips.
    func updateIfSecondChanged(elapsed: Double, duration: Double) {
        let second = Int(elapsed.rounded())
        guard second != lastPublishedSecond else { return }
        lastPublishedSecond = second
        update(elapsedOverride: elapsed)
    }
}
