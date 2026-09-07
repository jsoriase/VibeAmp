import Foundation
import Observation

/// 10-band EQ + preamp. Gain range matches classic Winamp: -12 dB … +12 dB.
struct EQSettings: Codable, Equatable, Sendable {
    static let frequencies: [Int] = [60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000]
    static let minGain: Double = -12
    static let maxGain: Double = 12

    var preamp: Double
    /// Band gains keyed by frequency Hz, in the same order as `frequencies`.
    var bands: [Int: Double]

    init(preamp: Double = 0, bands: [Int: Double]? = nil) {
        self.preamp = EQSettings.clamp(preamp)
        if let bands {
            self.bands = bands
        } else {
            self.bands = Dictionary(uniqueKeysWithValues: EQSettings.frequencies.map { ($0, 0.0) })
        }
        // Ensure every known band exists.
        for freq in EQSettings.frequencies where self.bands[freq] == nil {
            self.bands[freq] = 0
        }
    }

    static func clamp(_ value: Double) -> Double {
        min(maxGain, max(minGain, value))
    }

    func gain(for frequency: Int) -> Double {
        bands[frequency] ?? 0
    }

    mutating func setGain(_ gain: Double, for frequency: Int) {
        bands[frequency] = EQSettings.clamp(gain)
    }

    mutating func setPreamp(_ gain: Double) {
        preamp = EQSettings.clamp(gain)
    }

    var isFlat: Bool {
        preamp == 0 && EQSettings.frequencies.allSatisfy { (bands[$0] ?? 0) == 0 }
    }

    mutating func reset() {
        preamp = 0
        for freq in EQSettings.frequencies { bands[freq] = 0 }
    }

    /// Ordered gains for DSP: preamp first, then bands in frequency order.
    var orderedBandGains: [Double] {
        EQSettings.frequencies.map { bands[$0] ?? 0 }
    }

    // MARK: - Legacy dictionary persistence (freq string -> gain)

    init(fromLegacy dict: [String: Double]) {
        var bands: [Int: Double] = [:]
        var pre = 0.0
        for (key, value) in dict {
            if key == "preamp" {
                pre = EQSettings.clamp(value)
            } else if let freq = Int(key), EQSettings.frequencies.contains(freq) {
                bands[freq] = EQSettings.clamp(value)
            }
        }
        self.init(preamp: pre, bands: bands)
    }

    var legacyDictionary: [String: Double] {
        var dict: [String: Double] = ["preamp": preamp]
        for freq in EQSettings.frequencies { dict[String(freq)] = bands[freq] ?? 0 }
        return dict
    }

    // MARK: - Codable (supports both new and legacy shapes)

    enum CodingKeys: String, CodingKey {
        case preamp, bands
    }

    init(from decoder: Decoder) throws {
        // Distinguish modern {"preamp","bands"} from legacy flat {"preamp","60",...}
        // by the presence of the nested "bands" key.
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           container.contains(.bands) {
            let pre = (try? container.decode(Double.self, forKey: .preamp)) ?? 0
            let rawBands = (try? container.decode([String: Double].self, forKey: .bands)) ?? [:]
            var bands: [Int: Double] = [:]
            for (key, value) in rawBands {
                if let freq = Int(key) { bands[freq] = EQSettings.clamp(value) }
            }
            self.init(preamp: pre, bands: bands)
            return
        }
        // Fall back to a flat legacy dictionary.
        let flat = (try? decoder.singleValueContainer().decode([String: Double].self)) ?? [:]
        self.init(fromLegacy: flat)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(preamp, forKey: .preamp)
        var stringBands: [String: Double] = [:]
        for (freq, gain) in bands { stringBands[String(freq)] = gain }
        try container.encode(stringBands, forKey: .bands)
    }
}

@MainActor
@Observable
final class EQStore {
    var settings: EQSettings

    init(settings: EQSettings = EQSettings()) {
        self.settings = settings
    }

    func setGain(_ gain: Double, for frequency: Int) {
        settings.setGain(gain, for: frequency)
    }

    func setPreamp(_ gain: Double) {
        settings.setPreamp(gain)
    }

    func reset() {
        settings.reset()
    }
}
