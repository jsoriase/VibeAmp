import Foundation
import Observation
import AppKit
import UniformTypeIdentifiers

/// Explicit pasteboard payload shared by queue reordering and saved playlists.
struct QueueTrackDrag: Codable {
    static let typeIdentifier = "com.vibeamp.queue-track"
    let track: Track
    let sourceIndex: Int

    func pasteboardItem() -> NSPasteboardItem? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType(Self.typeIdentifier))
        return item
    }

    func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = track.title
        let data = try? JSONEncoder().encode(self)
        provider.registerDataRepresentation(forTypeIdentifier: Self.typeIdentifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}

struct SavedPlaylist: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var tracks: [Track] = []
}

@MainActor
@Observable
final class SavedPlaylists {
    private(set) var items: [SavedPlaylist]
    private let store: StateStore

    init(store: StateStore) {
        self.store = store
        items = store.get([SavedPlaylist].self, key: "savedPlaylists", fallback: [])
    }

    @discardableResult
    func create() -> SavedPlaylist {
        var name = "Untitled Playlist"
        var suffix = 2
        while items.contains(where: { $0.name == name }) {
            name = "Untitled Playlist \(suffix)"
            suffix += 1
        }
        let playlist = SavedPlaylist(name: name)
        items.append(playlist)
        save()
        return playlist
    }

    func rename(_ id: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].name = clean
        save()
    }

    @discardableResult
    func add(_ tracks: [Track], to id: UUID) -> Bool {
        let valid = tracks.filter { Track.isHttpURL($0.webpageURL) }
        guard !valid.isEmpty, let index = items.firstIndex(where: { $0.id == id }) else { return false }
        items[index].tracks.append(contentsOf: valid)
        save()
        return true
    }

    func removeTrack(at index: Int, from id: UUID) {
        guard let playlist = items.firstIndex(where: { $0.id == id }),
              items[playlist].tracks.indices.contains(index) else { return }
        items[playlist].tracks.remove(at: index)
        save()
    }

    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    private func save() {
        store.set(key: "savedPlaylists", value: items)
    }
}
