import SwiftUI

struct PlayerView: View {
    @Environment(PlaybackController.self) private var playback
    @Environment(QueueStore.self) private var queue
    @Environment(EQStore.self) private var eq
    @Environment(WindowManager.self) private var windows
    @Environment(AppState.self) private var appState

    @State private var seekFraction: Double = 0
    @State private var isSeeking = false

    var body: some View {
        @Bindable var playbackBindable = playback
        RetroWindowChrome(role: .player) {
            VStack(spacing: 6) {
                // LCD display: time + visualizer | title + metrics
                HStack(spacing: 8) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(TimeFormatting.formatCounter(current: playback.currentTime, duration: playback.duration))
                            .font(VibeTheme.lcdFont(size: 28))
                            .foregroundStyle(VibeTheme.lcdGreen)
                            .shadow(color: VibeTheme.lcdGreen.opacity(0.5), radius: 4)
                            .monospacedDigit()
                            // "00:00" at 28pt needs ~84pt: in the old 80pt column
                            // it wrapped to two lines, which read as "00:0 / 0"
                            // and made the whole window overflow its frame.
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .accessibilityLabel("Elapsed time")
                        VisualizerBars(isPlaying: playback.isPlaying)
                    }
                    .frame(width: 96)
                    .padding(.trailing, 8)
                    .overlay(Rectangle().frame(width: 1).foregroundStyle(Color.white.opacity(0.12)), alignment: .trailing)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(playback.currentTrack?.title ?? playback.statusMessage)
                            .font(VibeTheme.lcdFont(size: 15))
                            .foregroundStyle(VibeTheme.lcdGreen)
                            .shadow(color: VibeTheme.lcdGreen.opacity(0.4), radius: 3)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("Current track")
                        HStack(spacing: 12) {
                            Text("\(playback.bitrateKbps == 0 ? 128 : playback.bitrateKbps) kbps")
                                .font(VibeTheme.lcdFont(size: 12))
                                .foregroundStyle(VibeTheme.lcdDimGreen)
                            Text("\(playback.sampleRateKHz == 0 ? 44 : playback.sampleRateKHz) kHz")
                                .font(VibeTheme.lcdFont(size: 12))
                                .foregroundStyle(VibeTheme.lcdDimGreen)
                            if playback.isBuffering {
                                Text("BUFFERING")
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .foregroundStyle(VibeTheme.warning)
                            } else {
                                Text(statusText)
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .foregroundStyle(VibeTheme.textSecondary)
                            }
                        }
                        if let uploader = playback.currentTrack?.uploader, !uploader.isEmpty {
                            Text(uploader)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(VibeTheme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(6)
                .background(VibeTheme.lcdBackground)
                .overlay(Rectangle().stroke(VibeTheme.borderDark, lineWidth: 1))

                // Seek
                Slider(
                    value: Binding(
                        get: { isSeeking ? seekFraction : (playback.duration > 0 ? playback.currentTime / playback.duration : 0) },
                        set: { seekFraction = $0 }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        isSeeking = editing
                        if !editing {
                            playback.seek(fraction: seekFraction)
                        }
                    }
                )
                .tint(VibeTheme.lcdGreen)
                .help("Seek")
                .accessibilityLabel("Seek")
                .disabled(playback.duration <= 0)

                // Transport + volume
                HStack {
                    HStack(spacing: 2) {
                        TransportButton(label: "◀◀", tooltip: "Previous track", disabled: !queue.canGoPrevious) {
                            appState.step(-1)
                        }
                        TransportButton(label: "▶", tooltip: "Play") {
                            playback.play()
                        }
                        TransportButton(label: "❚❚", tooltip: "Pause") {
                            playback.pause()
                        }
                        TransportButton(label: "■", tooltip: "Stop") {
                            playback.stop()
                        }
                        TransportButton(label: "▶▶", tooltip: "Next track", disabled: !queue.canGoNext) {
                            appState.step(1)
                        }
                    }
                    Spacer()
                    Text("VOL")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(VibeTheme.textSecondary)
                    Slider(value: $playbackBindable.volume, in: 0...1)
                        .tint(VibeTheme.lcdGreen)
                        .frame(width: 70)
                        .help("Volume")
                        .accessibilityLabel("Volume")
                        .onChange(of: playback.volume) { _, newValue in
                            playback.setVolume(newValue)
                        }
                }
                .padding(4)
                .background(Color.black.opacity(0.4))
                .overlay(Rectangle().stroke(VibeTheme.borderDark, lineWidth: 1))

                // Module toggles
                HStack(spacing: 4) {
                    ForEach([WindowRole.equalizer, .playlist, .search, .art, .log], id: \.self) { role in
                        ModuleToggle(role: role)
                    }
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusText: String {
        switch playback.status {
        case .idle: return "IDLE"
        case .loading: return "LOADING"
        case .playing: return "PLAYING"
        case .paused: return "PAUSED"
        case .stopped: return "STOPPED"
        case .failed: return "ERROR"
        }
    }
}

private struct TransportButton: View {
    let label: String
    let tooltip: String
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .frame(minWidth: 28, minHeight: 20)
        }
        .buttonStyle(RetroButtonStyle())
        .disabled(disabled)
        .help(tooltip)
        .accessibilityLabel(tooltip)
    }
}

private struct ModuleToggle: View {
    let role: WindowRole
    @Environment(WindowManager.self) private var windows

    var body: some View {
        Button {
            windows.toggle(role)
        } label: {
            Text(role.shortLabel)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(RetroButtonStyle(active: windows.isVisible(role)))
        .help("Toggle \(role.title)")
        .accessibilityLabel("Toggle \(role.title)")
    }
}

/// Lightweight mock spectrum: animated bars while playing, static otherwise.
/// Uses a repeating SwiftUI animation — no high-frequency timer.
private struct VisualizerBars: View {
    let isPlaying: Bool
    @State private var phase = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(0..<11, id: \.self) { index in
                Rectangle()
                    .fill(VibeTheme.lcdGreen.opacity(0.85))
                    .frame(width: 4, height: isPlaying ? (phase ? barHeight(index) : barHeight(index + 3)) : 3)
            }
        }
        .frame(height: 15)
        .onChange(of: isPlaying) { _, playing in
            phase = false
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true)) {
                phase = true
            }
        }
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let pattern: [CGFloat] = [4, 9, 6, 12, 5, 10, 7, 13, 4, 8, 6]
        return pattern[index % pattern.count]
    }
}
