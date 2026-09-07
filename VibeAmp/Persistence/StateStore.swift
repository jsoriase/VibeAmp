import Foundation

/// Debounced, atomic JSON store under ~/Library/Application Support/VibeAmp/state.json.
/// Corrupt or missing files degrade to defaults rather than failing launch.
/// Thread-safe via NSLock; marked unchecked Sendable for Swift 6 mode.
final class StateStore: @unchecked Sendable {
    static let writeDebounceNanoseconds: UInt64 = 500_000_000

    let fileURL: URL
    private let lock = NSLock()
    private var data: [String: Any] = [:]
    private var saveTask: Task<Void, Never>?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    convenience init() {
        self.init(fileURL: StateStore.defaultStateURL())
    }

    static func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("VibeAmp", isDirectory: true)
    }

    static func defaultStateURL() -> URL {
        supportDirectory().appendingPathComponent("state.json")
    }

    func load() {
        lock.lock()
        defer { lock.unlock() }
        guard let raw = try? Data(contentsOf: fileURL),
              let parsed = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
        else {
            data = [:]
            return
        }
        data = parsed
    }

    /// Decodes a Codable value for key, returning fallback on any failure.
    func get<T: Decodable>(_ type: T.Type = T.self, key: String, fallback: T) -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let value = data[key] else { return fallback }
        // Round-trip through JSON to decode mixed plist-style values.
        // Fragments allowed so top-level numbers/bools (volume, index) survive.
        guard JSONSerialization.isValidJSONObject(value) || value is NSNumber || value is String || value is NSNull,
              let raw = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let decoded = try? JSONDecoder().decode(T.self, from: raw)
        else { return fallback }
        return decoded
    }

    func getDouble(key: String, fallback: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        if let number = data[key] as? Double { return number }
        if let number = data[key] as? NSNumber { return number.doubleValue }
        if let int = data[key] as? Int { return Double(int) }
        return fallback
    }

    func getBool(key: String, fallback: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let value = data[key] as? Bool { return value }
        if let number = data[key] as? NSNumber { return number.boolValue }
        return fallback
    }

    func set<T: Encodable>(key: String, value: T) {
        lock.lock()
        if let raw = try? JSONEncoder().encode(value),
           let object = try? JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed]) {
            data[key] = object
        }
        lock.unlock()
        scheduleWrite()
    }

    func setDouble(key: String, value: Double) {
        lock.lock()
        data[key] = value
        lock.unlock()
        scheduleWrite()
    }

    private func scheduleWrite() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: StateStore.writeDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        let snapshot: [String: Any] = {
            lock.lock()
            defer { lock.unlock() }
            return data
        }()
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let raw = try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
            let temporary = fileURL.appendingPathExtension("tmp")
            try raw.write(to: temporary, options: .atomic)
            // Atomic promotion: remove-then-move is safe because we just wrote tmp.
            _ = try? FileManager.default.removeItem(at: fileURL)
            try FileManager.default.moveItem(at: temporary, to: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: fileURL.appendingPathExtension("tmp"))
            print("[VibeAmp] Could not persist application state: \(error.localizedDescription)")
        }
    }

    // MARK: - Test helpers (pure logic, no disk)

    /// Validates that a restored window rect intersects at least one screen work area.
    static func rectIntersectsAnyScreen(
        _ rect: CGRect,
        screens: [CGRect]
    ) -> Bool {
        screens.contains { screen in rect.intersects(screen) && !rect.isNull && rect.width > 0 && rect.height > 0 }
    }

    /// Clamps a window origin so the window stays fully on the given work area.
    static func clampedOrigin(for size: CGSize, desired: CGPoint, in workArea: CGRect) -> CGPoint {
        let x = max(workArea.minX, min(desired.x, workArea.maxX - size.width))
        let y = max(workArea.minY, min(desired.y, workArea.maxY - size.height))
        return CGPoint(x: x, y: y)
    }
}
