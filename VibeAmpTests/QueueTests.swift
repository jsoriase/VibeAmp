import XCTest
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
