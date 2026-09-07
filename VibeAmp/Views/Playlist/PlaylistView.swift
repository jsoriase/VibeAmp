import SwiftUI

struct PlaylistView: View {
    @Environment(QueueStore.self) private var queue
    @Environment(AppState.self) private var appState

    var body: some View {
        RetroWindowChrome(role: .playlist) {
            VStack(spacing: 6) {
                HStack {
                    Text("\(queue.entries.count) TRACKS")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(VibeTheme.textSecondary)
                    Spacer()
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
                    List {
                        ForEach(Array(queue.entries.enumerated()), id: \.element.id) { index, track in
                            HStack(spacing: 6) {
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
                                Spacer()
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
                                }
                                .buttonStyle(.plain)
                                .help("Remove track")
                                .accessibilityLabel("Remove \(track.title)")
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 4)
                            .background(index == queue.currentIndex ? VibeTheme.lcdDimGreen.opacity(0.35) : Color.clear)
                            .overlay(
                                Rectangle().stroke(VibeTheme.lcdGreen.opacity(index == queue.currentIndex ? 0.8 : 0), lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                appState.playIndex(index)
                            }
                            .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                            .listRowBackground(Color.black)
                            .accessibilityLabel("Play \(track.title)")
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
                }
            }
            .padding(8)
        }
        .frame(width: 380, height: 190)
    }
}
