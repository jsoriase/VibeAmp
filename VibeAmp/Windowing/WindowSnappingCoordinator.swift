import Foundation
import CoreGraphics

/// Pure snapping math + attachment-graph helpers. No AppKit here so the whole
/// thing is unit-testable without windows on screen.
enum WindowSnappingCoordinator {
    static let threshold: CGFloat = 15

    struct SnapResult {
        var origin: CGPoint
        var target: String?
    }

    /// Computes the snapped origin for `moving` against screen edges + other frames.
    /// - Parameters:
    ///   - moving: current frame of the dragged window
    ///   - others: role -> frame for every other visible VibeAmp window (excludes descendants)
    ///   - workArea: visible frame of the screen the window is on
    static func snap(
        moving: CGRect,
        others: [String: CGRect],
        workArea: CGRect,
        threshold: CGFloat = WindowSnappingCoordinator.threshold
    ) -> SnapResult {
        var x = moving.origin.x
        var y = moving.origin.y
        var target: String?

        // Screen edges.
        if abs(moving.minX - workArea.minX) <= threshold { x = workArea.minX }
        if abs(moving.minY - workArea.minY) <= threshold { y = workArea.minY }
        if abs(moving.maxX - workArea.maxX) <= threshold { x = workArea.maxX - moving.width }
        if abs(moving.maxY - workArea.maxY) <= threshold { y = workArea.maxY - moving.height }

        for (role, other) in others {
            let overlapsY = moving.minY < other.maxY && moving.maxY > other.minY
            let overlapsX = moving.minX < other.maxX && moving.maxX > other.minX
            if overlapsY {
                if abs(moving.maxX - other.minX) <= threshold {
                    x = other.minX - moving.width
                    target = role
                } else if abs(moving.minX - other.maxX) <= threshold {
                    x = other.maxX
                    target = role
                } else if abs(moving.minX - other.minX) <= threshold {
                    x = other.minX
                    target = role
                } else if abs(moving.maxX - other.maxX) <= threshold {
                    x = other.maxX - moving.width
                    target = role
                }
            }
            if overlapsX {
                if abs(moving.maxY - other.minY) <= threshold {
                    y = other.minY - moving.height
                    target = role
                } else if abs(moving.minY - other.maxY) <= threshold {
                    y = other.maxY
                    target = role
                } else if abs(moving.minY - other.minY) <= threshold {
                    y = other.minY
                    target = role
                } else if abs(moving.maxY - other.maxY) <= threshold {
                    y = other.maxY - moving.height
                    target = role
                }
            }
        }

        return SnapResult(origin: CGPoint(x: round(x), y: round(y)), target: target)
    }

    // MARK: - Attachment graph

    /// All descendants of `parent` (transitive), cycle-safe.
    static func descendants(of parent: String, in attachments: [String: String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = [parent]
        var stack: [String] = [parent]
        while let current = stack.popLast() {
            for (child, attachedTo) in attachments where attachedTo == current && !seen.contains(child) {
                seen.insert(child)
                result.append(child)
                stack.append(child)
            }
        }
        return result
    }

    /// Removes cycles from a restored attachment map so walks always terminate.
    static func sanitized(_ raw: [String: String], validRoles: Set<String>) -> [String: String] {
        var clean: [String: String] = [:]
        for (child, parent) in raw {
            if child == parent { continue }
            if !validRoles.contains(child) || !validRoles.contains(parent) { continue }
            clean[child] = parent
        }
        for child in clean.keys {
            var seen: Set<String> = [child]
            var current = clean[child]
            while let next = current {
                if seen.contains(next) {
                    clean.removeValue(forKey: child)
                    break
                }
                seen.insert(next)
                current = clean[next]
            }
        }
        return clean
    }
}
