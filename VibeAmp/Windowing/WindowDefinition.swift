import Foundation
import CoreGraphics

/// The six retro modules. Single source of truth for sizes + default offsets.
enum WindowRole: String, CaseIterable, Codable, Sendable {
    case player
    case equalizer
    case playlist
    case search
    case art
    case log

    var title: String {
        switch self {
        case .player: return "VIBEAMP"
        case .equalizer: return "EQUALIZER"
        case .playlist: return "PLAYLIST / QUEUE"
        case .search: return "SEARCH & STREAM"
        case .art: return "ALBUM ART"
        case .log: return "DEBUG LOG"
        }
    }

    /// Short label used by the player's module toggles.
    var shortLabel: String {
        switch self {
        case .player: return "PLR"
        case .equalizer: return "EQ"
        case .playlist: return "PL"
        case .search: return "SEARCH"
        case .art: return "ART"
        case .log: return "LOG"
        }
    }

    /// Column width shared by every module so the cluster tiles cleanly.
    static let columnWidth: CGFloat = 380

    var defaultSize: CGSize {
        switch self {
        case .player: return CGSize(width: Self.columnWidth, height: 212)
        case .equalizer: return CGSize(width: Self.columnWidth, height: 200)
        case .playlist: return CGSize(width: Self.columnWidth, height: 224)
        case .search: return CGSize(width: Self.columnWidth, height: 284)
        case .art: return CGSize(width: Self.columnWidth, height: 260)
        case .log: return CGSize(width: Self.columnWidth, height: 224)
        }
    }

    /// Default offset from the cluster's top-left corner. Derived from the
    /// sizes above so the three columns always dock flush — hard-coded values
    /// drifted out of sync with `defaultSize` and left visible seams.
    var defaultOffset: CGPoint {
        let column = Self.columnWidth
        switch self {
        case .player:
            return CGPoint(x: 0, y: 0)
        case .equalizer:
            return CGPoint(x: 0, y: WindowRole.player.defaultSize.height)
        case .playlist:
            return CGPoint(x: 0, y: WindowRole.player.defaultSize.height + WindowRole.equalizer.defaultSize.height)
        case .search:
            return CGPoint(x: column, y: 0)
        case .art:
            return CGPoint(x: column, y: WindowRole.search.defaultSize.height)
        case .log:
            return CGPoint(x: column * 2, y: 0)
        }
    }
}

enum WindowLayout {
    /// Height of the custom Winamp-style header. Everything that needs to know
    /// how tall a title bar is reads this: the chrome, shade collapse, and the
    /// window's minimum size.
    static let titleBarHeight: CGFloat = 24

    static let snapThreshold: CGFloat = 15

    /// Collapses to exactly the custom header height so only the title bar shows.
    static var shadeHeight: CGFloat { titleBarHeight }

    /// Total width of the default three-column cluster.
    static var clusterWidth: CGFloat { WindowRole.columnWidth * 3 }

    /// Default frames for a fresh launch, anchored at the given top-left origin
    /// (AppKit coordinates are bottom-left; callers convert).
    static func defaultFrames(originTopLeft: CGPoint) -> [WindowRole: CGRect] {
        var frames: [WindowRole: CGRect] = [:]
        for role in WindowRole.allCases {
            let size = role.defaultSize
            let offset = role.defaultOffset
            frames[role] = CGRect(
                x: originTopLeft.x + offset.x,
                y: originTopLeft.y - offset.y - size.height,
                width: size.width,
                height: size.height
            )
        }
        return frames
    }
}
