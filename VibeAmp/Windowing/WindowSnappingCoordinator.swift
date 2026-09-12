import Foundation
import CoreGraphics

/// Winamp's window snapping, ported from the algorithm Webamp reimplements
/// (github.com/captbaritone/webamp, `js/snapUtils.ts` + `js/resizeUtils.ts`).
///
/// Two things about this model are easy to get wrong, and the previous version
/// got both wrong:
///
/// 1. **Docking is not a stored relationship.** Winamp keeps no parent/child
///    graph. Which windows travel together is worked out from geometry at the
///    moment the drag starts: everything transitively touching the window you
///    grabbed. Nothing to persist, nothing to corrupt.
/// 2. **Only the main window carries the group.** Dragging the equalizer or the
///    playlist moves that window alone, even with others docked to it.
///
/// Pure math, no AppKit, so all of it is testable without windows on screen.
/// Rects are AppKit's bottom-left origin: `minY` is the bottom edge, `maxY` the
/// top. Webamp works top-left, so the vertical relations below are mirrored.
enum WindowSnappingCoordinator {
    static var threshold: CGFloat { WindowLayout.snapThreshold }

    /// A snapped position on one axis; nil means "no snap on this axis".
    struct Snap {
        var x: CGFloat?
        var y: CGFloat?
        var isEmpty: Bool { x == nil && y == nil }
    }

    static func near(_ a: CGFloat, _ b: CGFloat, threshold: CGFloat = threshold) -> Bool {
        abs(a - b) < threshold
    }

    /// Deliberately lenient: boxes count as facing each other on an axis when
    /// they are within the snap distance, not only when they truly overlap.
    /// That is what lets a window snap to a neighbour it meets at a corner.
    static func overlapX(_ a: CGRect, _ b: CGRect, threshold: CGFloat = threshold) -> Bool {
        a.minX <= b.maxX + threshold && b.minX <= a.maxX + threshold
    }

    static func overlapY(_ a: CGRect, _ b: CGRect, threshold: CGFloat = threshold) -> Bool {
        a.minY <= b.maxY + threshold && b.minY <= a.maxY + threshold
    }

    /// Where `a` would land if it snapped to `b`. Each axis takes the first
    /// matching relation in a fixed order — butt against the far edge first,
    /// then align the near edges — which is what gives Winamp its predictable
    /// "clicks into place" feel.
    static func snap(_ a: CGRect, to b: CGRect, threshold: CGFloat = threshold) -> Snap {
        var result = Snap()

        if overlapY(a, b, threshold: threshold) {
            if near(a.minX, b.maxX, threshold: threshold) {
                result.x = b.maxX                      // a's left edge against b's right
            } else if near(a.maxX, b.minX, threshold: threshold) {
                result.x = b.minX - a.width            // a's right edge against b's left
            } else if near(a.minX, b.minX, threshold: threshold) {
                result.x = b.minX                      // left edges flush
            } else if near(a.maxX, b.maxX, threshold: threshold) {
                result.x = b.maxX - a.width            // right edges flush
            }
        }

        if overlapX(a, b, threshold: threshold) {
            if near(a.maxY, b.minY, threshold: threshold) {
                result.y = b.minY - a.height           // a's top against b's bottom
            } else if near(a.minY, b.maxY, threshold: threshold) {
                result.y = b.maxY                      // a's bottom against b's top
            } else if near(a.maxY, b.maxY, threshold: threshold) {
                result.y = b.maxY - a.height           // top edges flush
            } else if near(a.minY, b.minY, threshold: threshold) {
                result.y = b.minY                      // bottom edges flush
            }
        }

        return result
    }

    /// How far `a` must move to snap to `b`. Zero on an axis that doesn't snap.
    static func snapDiff(_ a: CGRect, to b: CGRect, threshold: CGFloat = threshold) -> CGVector {
        let snapped = snap(a, to: b, threshold: threshold)
        return CGVector(
            dx: snapped.x.map { $0 - a.minX } ?? 0,
            dy: snapped.y.map { $0 - a.minY } ?? 0
        )
    }

    /// The offset that snaps a whole moving group to any stationary window.
    ///
    /// Webamp takes whichever pair it happens to reach first; we take the
    /// smallest non-zero offset per axis instead. Same feel, minus the
    /// dependence on iteration order — which windows you docked to used to
    /// change from one drag to the next.
    static func snapDiffManyToMany(
        _ moving: [CGRect],
        _ stationary: [CGRect],
        threshold: CGFloat = threshold
    ) -> CGVector {
        var bestX: CGFloat = 0
        var bestY: CGFloat = 0
        for a in moving {
            for b in stationary {
                let diff = snapDiff(a, to: b, threshold: threshold)
                if diff.dx != 0, bestX == 0 || abs(diff.dx) < abs(bestX) { bestX = diff.dx }
                if diff.dy != 0, bestY == 0 || abs(diff.dy) < abs(bestY) { bestY = diff.dy }
            }
        }
        return CGVector(dx: bestX, dy: bestY)
    }

    /// Magnetic edges are a small attraction, never a barrier between displays.
    /// The caller supplies the work area under the pointer on each drag update.
    static func snapToScreenEdgesDiff(_ box: CGRect, workArea: CGRect, threshold: CGFloat = threshold) -> CGVector {
        func correction(_ nearEdge: CGFloat, _ farEdge: CGFloat, _ min: CGFloat, _ max: CGFloat) -> CGFloat {
            let candidates = [min - nearEdge, max - farEdge].filter { abs($0) < threshold }
            return candidates.min { abs($0) < abs($1) } ?? 0
        }
        return CGVector(
            dx: correction(box.minX, box.maxX, workArea.minX, workArea.maxX),
            dy: correction(box.minY, box.maxY, workArea.minY, workArea.maxY)
        )
    }

    static func boundingBox(_ boxes: [CGRect]) -> CGRect {
        guard var result = boxes.first else { return .zero }
        for box in boxes.dropFirst() { result = result.union(box) }
        return result
    }

    /// Combines the raw drag offset with the snap corrections, the way Winamp
    /// does: an axis only one correction touches takes that correction; an axis
    /// both want gets the smaller pull.
    static func applyMultipleDiffs(_ initial: CGVector, _ diffs: [CGVector]) -> CGVector {
        guard var meta = diffs.first else { return initial }
        for diff in diffs.dropFirst() {
            meta = CGVector(
                dx: (meta.dx == 0 || diff.dx == 0) ? meta.dx + diff.dx : min(meta.dx, diff.dx),
                dy: (meta.dy == 0 || diff.dy == 0) ? meta.dy + diff.dy : min(meta.dy, diff.dy)
            )
        }
        return CGVector(dx: initial.dx + meta.dx, dy: initial.dy + meta.dy)
    }

    // MARK: - Groups

    /// Two windows are docked when one would snap to the other where it stands.
    static func abuts(_ a: CGRect, _ b: CGRect, threshold: CGFloat = threshold) -> Bool {
        !snap(a, to: b, threshold: threshold).isEmpty
    }

    /// Everything transitively docked to `start`, `start` included. This is the
    /// set that travels with the main window — computed fresh from geometry on
    /// every drag, never stored.
    static func connectedGroup(
        startingAt start: String,
        among frames: [String: CGRect],
        threshold: CGFloat = threshold
    ) -> Set<String> {
        guard let startFrame = frames[start] else { return [start] }
        var group: Set<String> = [start]
        var stack: [(String, CGRect)] = [(start, startFrame)]
        while let (_, frame) = stack.popLast() {
            for (candidate, candidateFrame) in frames.sorted(by: { $0.key < $1.key }) {
                guard !group.contains(candidate) else { continue }
                if abuts(candidateFrame, frame, threshold: threshold) {
                    group.insert(candidate)
                    stack.append((candidate, candidateFrame))
                }
            }
        }
        return group
    }

    // MARK: - Preserving docks across a size change (shade, resize)

    /// Windows sharing an exact edge, with overlap on the perpendicular axis.
    /// Unlike snapping this demands a real touch: it describes docks that
    /// already exist rather than ones the user is reaching for.
    ///
    /// `below[w]` is the window resting directly under `w`. Webamp also tracks
    /// a horizontal edge for double-size mode; every module here is a fixed
    /// 380pt wide, so nothing ever pushes its neighbour sideways.
    struct EdgeGraph {
        var below: [String: String] = [:]
    }

    static func edgeGraph(_ frames: [String: CGRect]) -> EdgeGraph {
        var graph = EdgeGraph()
        let ordered = frames.sorted { $0.key < $1.key }
        for (key, frame) in ordered {
            for (other, otherFrame) in ordered where other != key {
                if graph.below[key] == nil,
                   otherFrame.maxY == frame.minY,
                   otherFrame.minX < frame.maxX, frame.minX < otherFrame.maxX {
                    graph.below[key] = other
                }
            }
        }
        return graph
    }

    /// How far each window must move so the docks in `graph` survive the size
    /// changes in `sizeDiff`. Shading the player, for instance, walks the whole
    /// column underneath it up by the height it lost.
    static func positionDiff(graph: EdgeGraph, sizeDiff: [String: CGSize]) -> [String: CGVector] {
        var diff: [String: CGVector] = [:]
        for key in Set(graph.below.keys).union(graph.below.values).union(sizeDiff.keys) {
            diff[key] = .zero
        }

        // AppKit grows downward from a fixed top edge, so a window that loses
        // height drags everything docked beneath it up by the same amount.
        func walk(_ key: String, seen: inout Set<String>) {
            guard !seen.contains(key) else { return }
            seen.insert(key)
            let delta = -(sizeDiff[key]?.height ?? 0)
            guard let under = graph.below[key] else { return }
            diff[under] = CGVector(
                dx: diff[under]?.dx ?? 0,
                dy: (diff[under]?.dy ?? 0) + delta + (diff[key]?.dy ?? 0)
            )
            walk(under, seen: &seen)
        }

        // Start from the windows nothing rests on, so parents are resolved
        // before the windows they push around.
        var seen: Set<String> = []
        let hasSomethingAbove = Set(graph.below.values)
        for key in diff.keys.sorted() where !hasSomethingAbove.contains(key) {
            walk(key, seen: &seen)
        }
        return diff
    }
}
