import SwiftUI

struct PlaylistView: View {
    @Environment(QueueStore.self) private var queue
    @Environment(AppState.self) private var appState

    /// Winamp-style: a click highlights a track, a double click starts it.
    @State private var selection: Track.ID?

    var body: some View {
        RetroWindowChrome(role: .playlist) {
            VStack(spacing: 6) {
                HStack {
                    Text("\(queue.entries.count) TRACKS")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(VibeTheme.textSecondary)
                    Text("DOUBLE-CLICK TO PLAY")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(VibeTheme.textSecondary.opacity(0.7))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button("CLEAR") {
                        queue.clear()
                        appState.persistEphemeral()
                    }
                    .buttonStyle(RetroButtonStyle())
                    .help("Clear queue")
                    .accessibilityLabel("Clear queue")
                    .disabled(queue.entries.isEmpty)
                }
                if queue.entries.isEmpty {
                    VStack {
                        Spacer()
                        Text("QUEUE EMPTY")
                            .font(VibeTheme.lcdFont(size: 16))
                            .foregroundStyle(VibeTheme.lcdDimGreen)
                        Text("Search for music to fill it")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(VibeTheme.textSecondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .overlay(Rectangle().stroke(VibeTheme.borderDark, lineWidth: 1))
                } else {
                    List(selection: $selection) {
                        ForEach(Array(queue.entries.enumerated()), id: \.element.id) { index, track in
                            HStack(spacing: 6) {
                                // A Button, not .onTapGesture on the row: inside
                                // a List the row's tap gesture loses to the
                                // list's own click handling, so a single click
                                // only highlighted the track and you needed a
                                // double click to actually start it.
                                Text("\(index + 1).")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(VibeTheme.lcdDimGreen)
                                    .frame(width: 24, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(track.title)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(index == queue.currentIndex ? VibeTheme.lcdGreen : VibeTheme.textPrimary)
                                        .lineLimit(1)
                                    if !track.uploader.isEmpty {
                                        Text(track.uploader)
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(VibeTheme.textSecondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 4)
                                if !track.durationString.isEmpty {
                                    Text(track.durationString)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(VibeTheme.textSecondary)
                                }
                                Button {
                                    queue.remove(at: IndexSet(integer: index))
                                    appState.persistEphemeral()
                                } label: {
                                    Text("✕")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(VibeTheme.textSecondary)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Remove track")
                                .accessibilityLabel("Remove \(track.title)")
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 4)
                            // Playing and selected are different things and read
                            // differently: green wash for the track that's
                            // sounding, a grey highlight for the one you picked.
                            .background(rowBackground(index: index, isSelected: selection == track.id))
                            .overlay(
                                Rectangle().stroke(
                                    selection == track.id ? VibeTheme.lcdGreen.opacity(0.9)
                                        : VibeTheme.lcdGreen.opacity(index == queue.currentIndex ? 0.55 : 0),
                                    lineWidth: 1
                                )
                            )
                            .contentShape(Rectangle())
                            // The list itself handles the single click (that's
                            // the selection); a second click starts playback.
                            .onTapGesture(count: 2) {
                                appState.playIndex(index)
                            }
                            .tag(track.id)
                            .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                            .listRowBackground(Color.black)
                            .accessibilityLabel(track.title)
                            .accessibilityHint("Double-click to play")
                        }
                        .onMove { source, destination in
                            queue.move(from: source, to: destination)
                            appState.persistEphemeral()
                        }
                        .onDelete { offsets in
                            queue.remove(at: offsets)
                            appState.persistEphemeral()
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color.black)
                    .overlay(Rectangle().stroke(VibeTheme.borderDark, lineWidth: 1))
                    .onKeyPress(.return) {
                        guard let selection, let index = queue.entries.firstIndex(where: { $0.id == selection }) else {
                            return .ignored
                        }
                        appState.playIndex(index)
                        return .handled
                    }
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func rowBackground(index: Int, isSelected: Bool) -> Color {
        if index == queue.currentIndex { return VibeTheme.lcdDimGreen.opacity(0.35) }
        if isSelected { return VibeTheme.panelRaised.opacity(0.9) }
        return .clear
    }
}
