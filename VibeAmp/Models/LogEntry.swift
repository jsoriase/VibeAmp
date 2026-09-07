import Foundation
import Observation

enum LogLevel: String, Codable, Sendable, CaseIterable {
    case info, warning, error
}

struct LogEntry: Identifiable, Codable, Sendable {
    var id = UUID()
    var level: LogLevel
    var message: String
    var time: String

    init(level: LogLevel, message: String, time: String = LogEntry.timestamp()) {
        self.id = UUID()
        self.level = level
        self.message = message
        self.time = time
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter.string(from: Date())
    }

    enum CodingKeys: String, CodingKey {
        case level, message, time
    }
}

/// Lightweight terminal-like logger. Displayed in the LOG window.
/// Caps history to prevent unbounded memory growth.
@MainActor
@Observable
final class AppLog {
    static let maxEntries = 200

    var entries: [LogEntry] = []

    func log(_ level: LogLevel, _ message: String) {
        let entry = LogEntry(level: level, message: message)
        entries.append(entry)
        while entries.count > Self.maxEntries {
            entries.removeFirst()
        }
        if level == .error {
            print("[VibeAmp][error] \(message)")
        } else {
            print("[VibeAmp][\(level.rawValue)] \(message)")
        }
    }

    func info(_ message: String) { log(.info, message) }
    func warning(_ message: String) { log(.warning, message) }
    func error(_ message: String) { log(.error, message) }

    func clear() {
        entries.removeAll()
    }
}
