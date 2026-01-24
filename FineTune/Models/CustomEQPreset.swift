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
}
