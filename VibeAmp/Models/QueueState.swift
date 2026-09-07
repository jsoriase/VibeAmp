import Foundation
import Observation

/// Playback queue: ordered entries + current index.
/// All mutation happens on the main actor so every window observes one truth.
@MainActor
@Observable
final class QueueStore {
    var entries: [Track] = []
    var currentIndex: Int = -1

    var currentTrack: Track? {
        guard currentIndex >= 0 && currentIndex < entries.count else { return nil }
        return entries[currentIndex]
    }

    var canGoPrevious: Bool { currentIndex > 0 }
    var canGoNext: Bool { currentIndex >= 0 && currentIndex < entries.count - 1 }

    init(entries: [Track] = [], currentIndex: Int = -1) {
        self.entries = entries
        self.currentIndex = currentIndex
    }

    func addAndPlay(_ track: Track) {
        entries.append(track)
        currentIndex = entries.count - 1
    }

    func replaceAndPlay(_ newEntries: [Track]) {
        let valid = newEntries.filter { !$0.webpageURL.isEmpty }
        entries = Array(valid.prefix(500))
        currentIndex = entries.isEmpty ? -1 : 0
    }

    func playIndex(_ index: Int) -> Track? {
        guard index >= 0 && index < entries.count else { return nil }
        currentIndex = index
        return entries[index]
    }

    /// Returns the new current track, or nil when stepping out of bounds.
    @discardableResult
    func step(_ delta: Int) -> Track? {
        let next = currentIndex + delta
        guard next >= 0 && next < entries.count else { return nil }
        currentIndex = next
        return entries[next]
    }

    /// Returns the track `delta` away from current without changing state.
    /// Used for next-track prefetching.
    func peek(_ delta: Int) -> Track? {
        let index = currentIndex + delta
        guard index >= 0 && index < entries.count else { return nil }
        return entries[index]
    }

    func remove(at offsets: IndexSet) {
        // Adjust currentIndex so it keeps pointing at the same track when possible.
        let sorted = offsets.sorted()
        var newIndex = currentIndex
        for removed in sorted.reversed() {
            if removed < newIndex {
                newIndex -= 1
            } else if removed == newIndex {
                // Removing the current track: stay at the same position,
                // which now holds the next track — or move back if at the end.
                // Resolved after removal below.
            }
            entries.remove(at: removed)
        }
        if entries.isEmpty {
            currentIndex = -1
        } else if sorted.contains(currentIndex) {
            // Current was removed: clamp to a valid neighbour (prefer next).
            currentIndex = min(currentIndex, entries.count - 1)
        } else {
            currentIndex = max(-1, min(newIndex, entries.count - 1))
        }
    }

    func removeTrack(id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        remove(at: IndexSet(integer: index))
    }

    func clear() {
        entries.removeAll()
        currentIndex = -1
    }

    func move(from source: IndexSet, to destination: Int) {
        // Reorder while keeping the current track identity stable.
        let currentID = currentTrack?.id
        var dest = destination
        // Account for removal shifting: standard SwiftUI move semantics.
        var moved: [Track] = []
        let sortedSource = source.sorted(by: >)
        for index in sortedSource {
            moved.insert(entries.remove(at: index), at: 0)
            if index < dest { dest -= 1 }
        }
        dest = max(0, min(dest, entries.count))
        entries.insert(contentsOf: moved, at: dest)
        if let currentID, let newIndex = entries.firstIndex(where: { $0.id == currentID }) {
            currentIndex = newIndex
        }
    }

    // MARK: - Persistence

    struct Persisted: Codable {
        var entries: [Track]
        var currentIndex: Int
    }

    func snapshot() -> Persisted {
        Persisted(entries: Array(entries.prefix(500)), currentIndex: currentIndex)
    }

    func restore(_ persisted: Persisted) {
        entries = persisted.entries.filter { !$0.webpageURL.isEmpty }
        if entries.isEmpty {
            currentIndex = -1
        } else {
            currentIndex = (persisted.currentIndex >= 0 && persisted.currentIndex < entries.count)
                ? persisted.currentIndex : -1
        }
    }
}
