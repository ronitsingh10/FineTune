import Foundation

struct EQSettings: Codable, Equatable {
    static let bandCount = 10
    static let maxGainDB: Float = 12.0
    static let minGainDB: Float = -12.0

    /// ISO standard frequencies for 10-band graphic EQ
    static let frequencies: [Double] = [
        31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000
    ]

    /// Gain in dB for each band (-12 to +12)
    var bandGains: [Float]

    /// Whether EQ processing is enabled
    var isEnabled: Bool

    init(bandGains: [Float] = Array(repeating: 0, count: 10), isEnabled: Bool = false) {
        self.bandGains = bandGains
        self.isEnabled = isEnabled
    }

    /// Returns gains clamped to valid range
    var clampedGains: [Float] {
        bandGains.map { max(Self.minGainDB, min(Self.maxGainDB, $0)) }
    }

    /// Flat EQ preset
    static let flat = EQSettings()
}
