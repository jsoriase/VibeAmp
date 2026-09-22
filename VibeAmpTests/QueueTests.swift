import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import VibeAmp

@MainActor
final class QueueTests: XCTestCase {
    private func makeTracks(_ count: Int) -> [Track] {
        (0..<count).map { i in
            Track(
                id: "id\(i)",
                title: "Track \(i)",
                uploader: "Uploader \(i)",
                durationString: "3:00",
                webpageURL: "https://www.youtube.com/watch?v=id\(i)"
            )
        }
    }

    func testAddAndPlay() {
        let queue = QueueStore()
        let tracks = makeTracks(2)
        queue.addAndPlay(tracks[0])
        XCTAssertEqual(queue.entries.count, 1)
        XCTAssertEqual(queue.currentIndex, 0)
        queue.addAndPlay(tracks[1])
        XCTAssertEqual(queue.entries.count, 2)
        XCTAssertEqual(queue.currentIndex, 1)
        XCTAssertEqual(queue.currentTrack?.id, "id1")
    }

    func testInsertAtBeginningKeepsCurrentTrackAndDoesNotSelectInsertedTrack() {
        let tracks = makeTracks(4)
        let queue = QueueStore(entries: Array(tracks.prefix(3)), currentIndex: 1)

        XCTAssertEqual(queue.insert(tracks[3], at: .beginning), 0)

        XCTAssertEqual(queue.entries.map(\.id), ["id3", "id0", "id1", "id2"])
        XCTAssertEqual(queue.currentIndex, 2)
        XCTAssertEqual(queue.currentTrack?.id, "id1")
    }

    func testInsertNextPlacesTrackAfterCurrentWithoutChangingPlayback() {
        let tracks = makeTracks(4)
        let queue = QueueStore(entries: Array(tracks.prefix(3)), currentIndex: 1)

        XCTAssertEqual(queue.insert(tracks[3], at: .next), 2)

        XCTAssertEqual(queue.entries.map(\.id), ["id0", "id1", "id3", "id2"])
        XCTAssertEqual(queue.currentIndex, 1)
        XCTAssertEqual(queue.currentTrack?.id, "id1")
        XCTAssertEqual(queue.peek(1)?.id, "id3")
    }

    func testInsertAtEndKeepsCurrentTrack() {
        let tracks = makeTracks(4)
        let queue = QueueStore(entries: Array(tracks.prefix(3)), currentIndex: 1)

        XCTAssertEqual(queue.insert(tracks[3], at: .end), 3)

        XCTAssertEqual(queue.entries.map(\.id), ["id0", "id1", "id2", "id3"])
        XCTAssertEqual(queue.currentIndex, 1)
        XCTAssertEqual(queue.currentTrack?.id, "id1")
    }

    func testInsertNextWithoutCurrentUsesBeginningAndLeavesQueueUnselected() {
        let tracks = makeTracks(3)
        let queue = QueueStore(entries: Array(tracks.prefix(2)), currentIndex: -1)

        XCTAssertEqual(queue.insert(tracks[2], at: .next), 0)

        XCTAssertEqual(queue.entries.map(\.id), ["id2", "id0", "id1"])
        XCTAssertEqual(queue.currentIndex, -1)
        XCTAssertNil(queue.currentTrack)
    }

    func testReplaceAndPlay() {
        let queue = QueueStore()
        queue.replaceAndPlay(makeTracks(3))
        XCTAssertEqual(queue.entries.count, 3)
        XCTAssertEqual(queue.currentIndex, 0)
        queue.replaceAndPlay([])
        XCTAssertEqual(queue.currentIndex, -1)
        XCTAssertTrue(queue.entries.isEmpty)
    }

    func testStepBounds() {
        let queue = QueueStore()
        queue.replaceAndPlay(makeTracks(3))
        XCTAssertNotNil(queue.step(1))
        XCTAssertEqual(queue.currentIndex, 1)
        XCTAssertNotNil(queue.step(-1))
        XCTAssertEqual(queue.currentIndex, 0)
        XCTAssertNil(queue.step(-1))
        XCTAssertEqual(queue.currentIndex, 0)
        queue.playIndex(2)
        XCTAssertNil(queue.step(1))
        XCTAssertEqual(queue.currentIndex, 2)
    }

    func testPlayIndexValidation() {
        let queue = QueueStore()
        queue.replaceAndPlay(makeTracks(2))
        XCTAssertNil(queue.playIndex(5))
        XCTAssertNil(queue.playIndex(-1))
        XCTAssertEqual(queue.currentIndex, 0)
        XCTAssertNotNil(queue.playIndex(1))
        XCTAssertEqual(queue.currentIndex, 1)
    }

    func testRemoveKeepsCurrentStable() {
        let queue = QueueStore()
        queue.replaceAndPlay(makeTracks(4))
        queue.playIndex(2)
        queue.remove(at: IndexSet(integer: 0))
        XCTAssertEqual(queue.currentIndex, 1)
        XCTAssertEqual(queue.currentTrack?.id, "id2")
        // Removing current moves to neighbour (next).
        queue.remove(at: IndexSet(integer: 1))
        XCTAssertEqual(queue.currentTrack?.id, "id3")
    }

    func testRemoveAllClearsIndex() {
        let queue = QueueStore()
        queue.replaceAndPlay(makeTracks(2))
        queue.remove(at: IndexSet([0, 1]))
        XCTAssertTrue(queue.entries.isEmpty)
        XCTAssertEqual(queue.currentIndex, -1)
    }

    func testMoveKeepsCurrentIdentity() {
        let queue = QueueStore()
        queue.replaceAndPlay(makeTracks(4))
        queue.playIndex(0)
        queue.move(from: IndexSet(integer: 0), to: 4)
        XCTAssertEqual(queue.entries.last?.id, "id0")
        XCTAssertEqual(queue.currentIndex, 3)
    }

    func testSnapshotRestore() {
        let queue = QueueStore()
        queue.replaceAndPlay(makeTracks(3))
        queue.playIndex(1)
        let snapshot = queue.snapshot()
        let restored = QueueStore()
        restored.restore(snapshot)
        XCTAssertEqual(restored.entries.count, 3)
        XCTAssertEqual(restored.currentIndex, 1)
    }

    func testCannotGoBeyondBounds() {
        let queue = QueueStore()
        XCTAssertFalse(queue.canGoPrevious)
        XCTAssertFalse(queue.canGoNext)
        queue.replaceAndPlay(makeTracks(2))
        XCTAssertFalse(queue.canGoPrevious)
        XCTAssertTrue(queue.canGoNext)
    }
}

@MainActor
final class SavedPlaylistsTests: XCTestCase {
    func testPlaylistsPersistIndependentlyOfQueue() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
        let library = SavedPlaylists(store: store)
        let first = library.create()
        let second = library.create()
        XCTAssertNotEqual(first.name, second.name)
        library.rename(first.id, to: "  Favorites  ")
        let track = Track(id: "a", title: "Song", webpageURL: "https://www.youtube.com/watch?v=a")
        let queue = QueueStore(entries: [track], currentIndex: 0)
        XCTAssertTrue(library.add(queue.entries, to: first.id))
        XCTAssertEqual(queue.entries, [track])
        XCTAssertEqual(queue.currentIndex, 0)
        queue.clear()
        store.flush()
        let restoredStore = StateStore(fileURL: store.fileURL)
        restoredStore.load()
        let restored = SavedPlaylists(store: restoredStore)
        XCTAssertEqual(restored.items.count, 2)
        XCTAssertEqual(restored.items[0].name, "Favorites")
        XCTAssertEqual(restored.items[0].tracks, [track])
        XCTAssertTrue(restored.items[1].tracks.isEmpty)
    }

    func testEditingOnePlaylistDoesNotChangeAnother() {
        let store = StateStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json"))
        defer {
            store.flush()
            try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent())
        }
        let library = SavedPlaylists(store: store)
        let first = library.create()
        let second = library.create()
        let track = Track(id: "a", title: "Song", webpageURL: "https://youtu.be/a")
        XCTAssertTrue(library.add([track, track], to: first.id))
        XCTAssertTrue(library.add([track], to: second.id))
        library.removeTrack(at: 1, from: first.id)
        XCTAssertEqual(library.items[0].tracks, [track])
        library.rename(first.id, to: " \n ")
        XCTAssertEqual(library.items[0].name, first.name)
        library.delete(first.id)
        XCTAssertEqual(library.items.map(\.id), [second.id])
        XCTAssertEqual(library.items[0].tracks, [track])
        XCTAssertFalse(library.add([track], to: first.id))
    }
}

@MainActor
final class PlaylistDragTests: XCTestCase {
    func testQueueDragTypeIsDeclaredForSwiftUIDrop() throws {
        let declarations = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]])
        let declaration = try XCTUnwrap(declarations.first { $0["UTTypeIdentifier"] as? String == QueueTrackDrag.typeIdentifier })
        XCTAssertEqual(declaration["UTTypeConformsTo"] as? [String], [UTType.json.identifier])
        let tags = try XCTUnwrap(declaration["UTTypeTagSpecification"] as? [String: String])
        XCTAssertEqual(tags["com.apple.nspboard-type"], QueueTrackDrag.typeIdentifier)
    }

    func testNativeQueuePasteboardPreservesTrack() throws {
        let track = Track(id: "native", title: "Native drag", webpageURL: "https://youtu.be/native")
        let item = try XCTUnwrap(QueueTrackDrag(track: track, sourceIndex: 2).pasteboardItem())
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let data = try XCTUnwrap(pasteboard.data(forType: NSPasteboard.PasteboardType(QueueTrackDrag.typeIdentifier)))
        let payload = try JSONDecoder().decode(QueueTrackDrag.self, from: data)
        XCTAssertEqual(payload.track, track)
        XCTAssertEqual(payload.sourceIndex, 2)
    }

    func testQueuePasteboardPayloadCanBeLoadedAndCopied() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
        defer { store.flush(); try? FileManager.default.removeItem(at: directory) }
        let track = Track(id: "drag", title: "Song to copy", webpageURL: "https://youtu.be/drag")
        let queue = QueueStore(entries: [track], currentIndex: 0)
        let provider = QueueTrackDrag(track: track, sourceIndex: 0).itemProvider()
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(QueueTrackDrag.typeIdentifier))
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: QueueTrackDrag.typeIdentifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadCorruptFile)) }
            }
        }
        let payload = try JSONDecoder().decode(QueueTrackDrag.self, from: data)
        XCTAssertEqual(payload.sourceIndex, 0)
        XCTAssertEqual(payload.track, track)
        let library = SavedPlaylists(store: store)
        let destination = library.create()
        XCTAssertTrue(library.add([payload.track], to: destination.id))
        XCTAssertEqual(library.items[0].tracks, queue.entries)
        XCTAssertEqual(queue.currentIndex, 0)
    }
}
