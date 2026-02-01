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
    
    // MARK: - Parametric Mode
    
    enum Mode: String, Codable {
        case graphic
        case parametric
    }
    
    var mode: Mode = .graphic
    
    /// Preamp gain in dB (applied in both modes)
    var preampGain: Float = 0.0
    
    /// Bands for Parametric mode
    var parametricBands: [EQBand] = []

    init(bandGains: [Float] = Array(repeating: 0, count: 10), isEnabled: Bool = true) {
        self.bandGains = bandGains
        self.isEnabled = isEnabled
    }
    
    /// Parse parametric text format
    /// Format: "Filter 1: ON LS Fc 105.0 Hz Gain 11.2 dB Q 0.70"
    static func parseParametricText(_ text: String) -> (preamp: Float, bands: [EQBand]) {
        var preamp: Float = 0.0
        var bands: [EQBand] = []
        
        let lines = text.components(separatedBy: .newlines)
        
        for line in lines {
            let trim = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trim.isEmpty { continue }
            
            // Check for Preamp
            if trim.lowercased().hasPrefix("preamp:") {
                // Example: "Preamp: -12.88 dB"
                let components = trim.components(separatedBy: " ")
                if components.count >= 2, let val = Float(components[1]) {
                    preamp = val
                }
                continue
            }
            
            // Check for Filter
            // "Filter 1: ON LS Fc 105.0 Hz Gain 11.2 dB Q 0.70"
            if trim.lowercased().hasPrefix("filter") {
                // Simple parsing strategy: split by space and look for keywords
                let parts = trim.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                
                // Check if active (e.g. "Filter 1: ON ...")
                let isEnabled = parts.contains("ON")
                
                // Type
                var type: FilterType = .peak // Default
                if parts.contains("LS") { type = .lowShelf }
                else if parts.contains("HS") { type = .highShelf }
                else if parts.contains("PK") { type = .peak }
                
                // Frequency "Fc 105.0 Hz"
                var freq: Double = 1000.0
                if let idx = parts.firstIndex(of: "Fc"), idx + 1 < parts.count {
                    freq = Double(parts[idx + 1]) ?? 1000.0
                }
                
                // Gain "Gain 11.2 dB"
                var gain: Float = 0.0
                if let idx = parts.firstIndex(of: "Gain"), idx + 1 < parts.count {
                    gain = Float(parts[idx + 1]) ?? 0.0
                }
                
                // Q "Q 0.70"
                var q: Double = 0.7
                if let idx = parts.firstIndex(of: "Q"), idx + 1 < parts.count {
                    q = Double(parts[idx + 1]) ?? 0.7
                }
                
                let band = EQBand(
                    type: type,
                    frequency: freq,
                    gain: gain,
                    Q: q,
                    isEnabled: isEnabled
                )
                bands.append(band)
            }
        }
        
        return (preamp, bands)
    }

    /// Returns gains clamped to valid range
    var clampedGains: [Float] {
        bandGains.map { max(Self.minGainDB, min(Self.maxGainDB, $0)) }
    }

    /// Flat EQ preset
    static let flat = EQSettings()
}
