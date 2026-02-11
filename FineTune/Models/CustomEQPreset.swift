import Foundation

struct CustomEQPreset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var preampGain: Float
    var bands: [EQBand]
    
    init(id: UUID = UUID(), name: String, preampGain: Float, bands: [EQBand]) {
        self.id = id
        self.name = name
        self.preampGain = preampGain
        self.bands = bands
    }
    
    /// Serializes the preset back to the standard text format for editing.
    var configurationText: String {
        var lines: [String] = []
        
        // Preamp line if non-zero
        if abs(preampGain) > 0.01 {
            lines.append("Preamp: \(String(format: "%.1f", preampGain)) dB")
        }
        
        // Filter lines
        for (index, band) in bands.enumerated() {
            let typeStr: String
            switch band.type {
            case .peak: typeStr = "PK"
            case .lowShelf: typeStr = "LSC"
            case .highShelf: typeStr = "HSC"
            }
            let status = band.isEnabled ? "ON" : "OFF"
            let line = "Filter \(index + 1): \(status) \(typeStr) Fc \(Int(band.frequency)) Hz Gain \(String(format: "%.1f", band.gain)) dB Q \(String(format: "%.2f", band.Q))"
            lines.append(line)
        }
        
        return lines.joined(separator: "\n")
    }
}
