import SwiftUI

struct SearchView: View {
    @Environment(AppState.self) private var appState

    @State private var query: String = ""
    @State private var status: String = ""
    @State private var results: [YTDLPModels.SearchResult] = []
    @State private var isWorking = false
    @State private var searchTask: Task<Void, Never>?
    @State private var sequence = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        RetroWindowChrome(role: .search) {
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    TextField("Search YouTube...", text: $query)
                        .textFieldStyle(.plain)
                        .font(VibeTheme.lcdFont(size: 15))
                        .foregroundStyle(VibeTheme.lcdGreen)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        .background(Color.black)
                        .overlay(Rectangle().stroke(VibeTheme.borderDark, lineWidth: 1))
                        .focused($fieldFocused)
                        .help("Search YouTube or paste a video/playlist URL (⌘L)")
                        .accessibilityLabel("Search YouTube or enter URL")
                        .onChange(of: query) { _, newValue in
                            handleInput(newValue)
                        }
                        .onSubmit {
                            handleStreamClick()
                        }
                    Button("STREAM") {
                        handleStreamClick()
                    }
                    .buttonStyle(RetroButtonStyle())
                    .disabled(isWorking)
                    .help("Play URL or top search result (Enter)")
                    .accessibilityLabel("Stream")
                }

                Text(status)
                    .font(VibeTheme.lcdFont(size: 13))
                    .foregroundStyle(VibeTheme.lcdDimGreen)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
                    .frame(minHeight: 20)

                if results.isEmpty {
                    if !isWorking {
                        VStack {
                            Spacer()
                            Text("TYPE TO SEARCH — PASTE URL TO PLAY")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(VibeTheme.textSecondary)
                                .multilineTextAlignment(.center)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        HStack {
                            Spacer()
                            ProgressView()
                                .scaleEffect(0.7)
                                .tint(VibeTheme.lcdGreen)
                            Text("Searching…")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(VibeTheme.textSecondary)
                            Spacer()
                        }
                        .frame(maxHeight: .infinity)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(results, id: \.id) { item in
                                Button {
                                    selectResult(item)
                                } label: {
                                    HStack(spacing: 6) {
                                        AsyncImage(url: URL(string: item.thumbnailURL)) { image in
                                            image.resizable().aspectRatio(contentMode: .fill)
                                        } placeholder: {
                                            Rectangle().fill(VibeTheme.panelRaised)
                                        }
                                        .frame(width: 56, height: 32)
                                        .clipped()
                                        .overlay(Rectangle().stroke(VibeTheme.borderDark, lineWidth: 1))

                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.title)
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundStyle(VibeTheme.textPrimary)
                                                .lineLimit(2)
                                            HStack(spacing: 6) {
                                                if !item.uploader.isEmpty {
                                                    Text(item.uploader)
                                                        .font(.system(size: 9, design: .monospaced))
                                                        .foregroundStyle(VibeTheme.textSecondary)
                                                        .lineLimit(1)
                                                }
                                                if !item.durationString.isEmpty {
                                                    Text(item.durationString)
                                                        .font(.system(size: 9, design: .monospaced))
                                                        .foregroundStyle(VibeTheme.lcdDimGreen)
                                                }
                                            }
                                        }
                                        Spacer()
                                    }
                                    .padding(4)
                                    .background(Color.black.opacity(0.5))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Play \(item.title)")
                                .accessibilityLabel("Play \(item.title)")
                                .contextMenu {
                                    Button("Añadir al inicio") {
                                        enqueueResult(item, at: .beginning)
                                    }
                                    Button("Añadir siguiente") {
                                        enqueueResult(item, at: .next)
                                    }
                                    Button("Añadir final") {
                                        enqueueResult(item, at: .end)
                                    }
                                }
                            }
                        }
                    }
                    .background(Color.black)
                    .overlay(Rectangle().stroke(VibeTheme.borderDark, lineWidth: 1))
                }
            }
            .padding(8)
            .onReceive(NotificationCenter.default.publisher(for: .vibeAmpFocusSearch)) { _ in
                fieldFocused = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .vibeAmpFocusURL)) { _ in
                fieldFocused = true
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Debounced search (stale guard + cancellation)

    private func isURL(_ value: String) -> Bool {
        Track.isHttpURL(value)
    }

    private func handleInput(_ value: String) {
        searchTask?.cancel()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, !isURL(trimmed) else {
            results = []
            if trimmed.isEmpty { status = "" }
            return
        }
        sequence += 1
        let current = sequence
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            isWorking = true
            do {
                let found = try await appState.youtube.search(query: trimmed, limit: 8)
                guard !Task.isCancelled, current == sequence else { return }
                results = found
                status = found.isEmpty ? "No results found" : "Select a result to play"
                appState.log.info("Search '\(trimmed)' — \(found.count) results")
            } catch is CancellationError {
                // Superseded — stay silent.
            } catch {
                guard current == sequence else { return }
                status = "Error: \(error.localizedDescription)"
                appState.log.error("Error searching YouTube: \(error.localizedDescription)")
            }
            isWorking = false
        }
    }

    private func handleStreamClick() {
        let input = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            status = "Enter a search query or URL"
            return
        }
        searchTask?.cancel()
        sequence += 1
        let current = sequence
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                if isURL(input) {
                    status = "Analyzing URL…"
                    let info = try await appState.youtube.resolveURL(input)
                    guard current == sequence else { return }
                    switch info {
                    case .playlist(let title, let entries):
                        if entries.isEmpty {
                            status = "Playlist has no playable videos"
                        } else {
                            appState.replaceAndPlay(entries, title: title)
                            status = "Playing playlist: \(title)"
                            query = ""
                            results = []
                        }
                    case .video(let track):
                        appState.addAndPlay(track)
                        status = "Playing: \(track.title)"
                        query = ""
                        results = []
                    }
                    return
                }
                status = "Searching…"
                let found = try await appState.youtube.search(query: input, limit: 8)
                guard current == sequence else { return }
                results = found
                status = found.isEmpty ? "No results found" : "Select a result to play"
            } catch is CancellationError {
            } catch {
                guard current == sequence else { return }
                status = "Error: \(error.localizedDescription)"
                appState.log.error("Stream failed: \(error.localizedDescription)")
            }
        }
    }

    private func selectResult(_ item: YTDLPModels.SearchResult) {
        appState.addAndPlay(track(for: item))
        status = "Playing: \(item.title)"
        query = ""
        results = []
    }

    private func enqueueResult(_ item: YTDLPModels.SearchResult, at position: QueueStore.InsertionPosition) {
        appState.enqueue(track(for: item), at: position)
        switch position {
        case .beginning:
            status = "Añadido al inicio: \(item.title)"
        case .next:
            status = "Añadido como siguiente: \(item.title)"
        case .end:
            status = "Añadido al final: \(item.title)"
        }
    }

    private func track(for item: YTDLPModels.SearchResult) -> Track {
        Track(
            id: item.id,
            title: item.title,
            uploader: item.uploader,
            durationString: item.durationString,
            durationSeconds: item.durationSeconds,
            webpageURL: item.webpageURL,
            thumbnailURL: item.thumbnailURL
        )
    }
}
