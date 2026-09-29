import SwiftUI
import AppKit

struct SavedPlaylistsView: View {
    let appState: AppState
    @Environment(WindowManager.self) private var windows
    @State private var openedID: UUID?
    @State private var editingID: UUID?
    @State private var draftName = ""
    @State private var targetedID: UUID?

    private var library: SavedPlaylists { appState.playlists }
    private var opened: SavedPlaylist? { library.items.first { $0.id == openedID } }

    var body: some View {
        RetroWindowChrome(role: .savedPlaylists) {
            content.padding(8)
                .onDisappear { commitName() }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(VibeTheme.textPrimary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: windows.isVisible(.savedPlaylists)) { _, visible in
            if !visible { commitName() }
        }
    }

    private var content: some View {
        VStack(spacing: 8) {
            if let playlist = opened {
                playlistContents(playlist)
            } else {
                Text("Drag songs from the queue into a playlist")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(VibeTheme.textSecondary)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(library.items) { playlist in
                                playlistRow(playlist)
                                    .id(playlist.id)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .overlay(Rectangle().stroke(VibeTheme.borderDark))
                    .overlay {
                        if library.items.isEmpty {
                            emptyState("NO PLAYLISTS", detail: "Create your first playlist below")
                        }
                    }
                    .onChange(of: editingID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
                Button {
                    commitName()
                    let playlist = library.create()
                    draftName = playlist.name
                    editingID = playlist.id
                } label: {
                    Label("New Playlist", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RetroButtonStyle())
            }
        }

    }

    private func playlistRow(_ playlist: SavedPlaylist) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .foregroundStyle(VibeTheme.lcdGreen)
            VStack(alignment: .leading, spacing: 2) {
                if editingID == playlist.id {
                    PlaylistNameEditor(text: $draftName, onCommit: commitName, onCancel: { editingID = nil })
                        .frame(height: 22)
                } else {
                    Text(playlist.name).foregroundStyle(VibeTheme.lcdGreen).lineLimit(1)
                }
                Text("\(playlist.tracks.count) tracks")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(VibeTheme.textSecondary)
            }
            Spacer(minLength: 0)
            Button {
                commitName()
                openedID = playlist.id
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(RetroButtonStyle())
            .help("Open \(playlist.name)")
            .accessibilityLabel("Open \(playlist.name)")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .padding(.horizontal, 6)
        .background(targetedID == playlist.id ? VibeTheme.lcdDimGreen.opacity(0.4) : Color.clear)
        .onTapGesture(count: 2) {
            guard editingID != playlist.id else { return }
            commitName()
            openedID = playlist.id
        }
        .overlay(Rectangle().stroke(targetedID == playlist.id ? VibeTheme.lcdGreen : VibeTheme.borderDark))
        .onDrop(of: [QueueTrackDrag.typeIdentifier], delegate: PlaylistTrackDrop(
            operation: .copy,
            targeted: { targeted in targetedID = targeted ? playlist.id : nil },
            receive: { payload in _ = library.add([payload.track], to: playlist.id) }
        ))
        .retroContextMenu([
            RetroContextMenuAction(title: "Rename", symbol: "pencil") {
                commitName()
                draftName = playlist.name
                editingID = playlist.id
            },
            RetroContextMenuAction(title: "Delete Playlist", symbol: "trash", role: .destructive) {
                library.delete(playlist.id)
            }
        ])
    }

    private func playlistContents(_ playlist: SavedPlaylist) -> some View {
        VStack(spacing: 10) {
            HStack {
                Button { openedID = nil } label: { Image(systemName: "chevron.left") }
                    .help("Back to playlists")
                    .buttonStyle(RetroButtonStyle())
                Text(playlist.name).font(VibeTheme.lcdFont(size: 12)).foregroundStyle(VibeTheme.lcdGreen).lineLimit(1)
                Spacer()
                Button("Play") { appState.replaceAndPlay(playlist.tracks, title: playlist.name) }
                    .disabled(playlist.tracks.isEmpty)
                    .buttonStyle(RetroButtonStyle())
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                ForEach(Array(playlist.tracks.enumerated()), id: \.offset) { index, track in
                    HStack {
                        Text(track.title).lineLimit(2)
                        Spacer()
                        Button {
                            library.removeTrack(at: index, from: playlist.id)
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(RetroButtonStyle())
                            .help("Remove \(track.title)")
                    }
                }
                }
                .padding(6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .overlay(Rectangle().stroke(VibeTheme.borderDark))
            .overlay {
                if playlist.tracks.isEmpty {
                    emptyState("NO TRACKS", detail: "Drag songs here from the queue")
                }
            }
            .onDrop(of: [QueueTrackDrag.typeIdentifier], delegate: PlaylistTrackDrop(operation: .copy) { payload in
                _ = library.add([payload.track], to: playlist.id)
            })
            Text("Drag songs here to add them")
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(VibeTheme.textSecondary)
        }
    }

    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(VibeTheme.lcdFont(size: 16)).foregroundStyle(VibeTheme.lcdDimGreen)
            Text(detail).font(.system(size: 9, design: .monospaced)).foregroundStyle(VibeTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private func commitName() {
        if let id = editingID { library.rename(id, to: draftName) }
        editingID = nil
    }
}


private struct PlaylistNameEditor: NSViewRepresentable {
    @Binding var text: String
    let onCommit: () -> Void
    let onCancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NameField {
        let field = NameField(string: text)
        field.delegate = context.coordinator
        field.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        field.textColor = NSColor(VibeTheme.lcdGreen)
        field.backgroundColor = .black
        field.isBezeled = false
        field.setAccessibilityLabel("Playlist name")
        return field
    }
    func updateNSView(_ field: NameField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PlaylistNameEditor
        init(_ parent: PlaylistNameEditor) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.insertTab(_:)) {
                parent.onCommit()
                return true
            }
            return false
        }
    }
    final class NameField: NSTextField {
        private var didFocus = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !didFocus else { return }
            didFocus = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeKey()
                window.makeFirstResponder(self)
                self.selectText(nil)
            }
        }
    }
}

/// Report copy/move explicitly and decode the same registered data representation
/// on both sides; no List reordering drag competes with the cross-window drag.
struct PlaylistTrackDrop: DropDelegate {
    var operation: DropOperation
    var targeted: (Bool) -> Void = { _ in }
    var receive: (QueueTrackDrag) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [QueueTrackDrag.typeIdentifier]) }
    func dropEntered(info: DropInfo) { targeted(true) }
    func dropExited(info: DropInfo) { targeted(false) }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: operation) }
    func performDrop(info: DropInfo) -> Bool {
        targeted(false)
        let providers = info.itemProviders(for: [QueueTrackDrag.typeIdentifier])
        guard !providers.isEmpty else { return false }
        for provider in providers {
            provider.loadDataRepresentation(forTypeIdentifier: QueueTrackDrag.typeIdentifier) { data, _ in
                guard let data, let payload = try? JSONDecoder().decode(QueueTrackDrag.self, from: data) else { return }
                DispatchQueue.main.async { receive(payload) }
            }
        }
        return true
    }
}
