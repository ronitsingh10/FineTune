import Foundation

struct EQBand: Identifiable, Codable, Equatable {
    let id: UUID
    var type: FilterType
    var frequency: Double
    var gain: Float
    var Q: Double
    var isEnabled: Bool
    
    init(
        id: UUID = UUID(),
        type: FilterType = .peak,
        frequency: Double,
        gain: Float,
        Q: Double,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.type = type
        self.frequency = frequency
        self.gain = gain
        self.Q = Q
        self.isEnabled = isEnabled
    }
}
