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

    var defaultSize: CGSize {
        switch self {
        case .player: return CGSize(width: 380, height: 210)
        case .equalizer: return CGSize(width: 380, height: 168)
        case .playlist: return CGSize(width: 380, height: 190)
        case .search: return CGSize(width: 380, height: 260)
        case .art: return CGSize(width: 380, height: 260)
        case .log: return CGSize(width: 380, height: 210)
        }
    }

    /// Default offset from the player's origin (top-left cluster).
    /// Mirrors the original Electron WINDOW_DEFINITIONS layout.
    var defaultOffset: CGPoint {
        switch self {
        case .player: return CGPoint(x: 0, y: 0)
        case .equalizer: return CGPoint(x: 0, y: 218)
        case .playlist: return CGPoint(x: 0, y: 394)
        case .search: return CGPoint(x: 388, y: 0)
        case .art: return CGPoint(x: 388, y: 268)
        case .log: return CGPoint(x: 776, y: 0)
        }
    }
}

enum WindowLayout {
    static let snapThreshold: CGFloat = 15
    // Collapses to exactly the custom header height so only the title bar shows.
    static let shadeHeight: CGFloat = 24

    static let defaultAttachments: [WindowRole: WindowRole] = [
        .equalizer: .player,
        .playlist: .equalizer,
        .search: .player,
        .art: .search,
        .log: .search,
    ]

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
