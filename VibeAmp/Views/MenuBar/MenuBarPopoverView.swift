import SwiftUI

/// Native macOS mini player (deliberately NOT retro-skinned):
/// artwork, title, uploader, elapsed/remaining, seek, prev/play/next.
struct MenuBarPopoverView: View {
    @Environment(PlaybackController.self) private var playback
    @Environment(QueueStore.self) private var queue
    @Environment(AppState.self) private var appState

    @State private var seekFraction: Double = 0
    @State private var isSeeking = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Group {
                    if let urlString = playback.currentTrack?.thumbnailURL,
                       !urlString.isEmpty,
                       let url = URL(string: urlString) {
                        AsyncImage(url: url) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Image(systemName: "music.note")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Image(systemName: "music.note")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(playback.currentTrack?.title ?? "Nothing playing")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(playback.currentTrack?.uploader ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 16) {
                        Button {
                            appState.step(-1)
                        } label: {
                            Image(systemName: "backward.fill")
                        }
                        .disabled(!queue.canGoPrevious)
                        Button {
                            playback.toggle()
                        } label: {
                            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 16))
                        }
                        Button {
                            appState.step(1)
                        } label: {
                            Image(systemName: "forward.fill")
                        }
                        .disabled(!queue.canGoNext)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
                Spacer()
            }

            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { isSeeking ? seekFraction : (playback.duration > 0 ? playback.currentTime / playback.duration : 0) },
                        set: { seekFraction = $0 }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        isSeeking = editing
                        if !editing { playback.seek(fraction: seekFraction) }
                    }
                )
                .disabled(playback.duration <= 0)
                .accessibilityLabel("Seek")
                HStack {
                    Text(TimeFormatting.format(seconds: playback.currentTime))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(playback.duration > 0 ? "−\(TimeFormatting.format(seconds: max(0, playback.duration - playback.currentTime)))" : "0:00")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}
