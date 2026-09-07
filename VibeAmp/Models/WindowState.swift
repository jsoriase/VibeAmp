import Foundation

/// Persisted geometry + visibility for the six retro modules.
struct WindowState: Codable, Equatable, Sendable {
    var positions: [String: WindowPoint]
    var visible: [String: Bool]
    var shaded: [String: Bool]
    var attachments: [String: String]

    struct WindowPoint: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
    }

    init(
        positions: [String: WindowPoint] = [:],
        visible: [String: Bool] = [:],
        shaded: [String: Bool] = [:],
        attachments: [String: String] = [:]
    ) {
        self.positions = positions
        self.visible = visible
        self.shaded = shaded
        self.attachments = attachments
    }
}
