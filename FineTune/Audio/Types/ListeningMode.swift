enum ListeningMode: UInt8, CaseIterable, Identifiable {
    case off = 1
    case noiseCancellation = 2
    case transparency = 3
    case adaptive = 4

    var id: UInt8 { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .noiseCancellation: return "Noise Cancellation"
        case .transparency: return "Transparency"
        case .adaptive: return "Adaptive"
        }
    }

    var abbreviatedName: String {
        switch self {
        case .off: return "Off"
        case .noiseCancellation: return "ANC"
        case .transparency: return "Trans."
        case .adaptive: return "Adapt."
        }
    }

    var iconName: String {
        switch self {
        case .off: return "ear"
        case .noiseCancellation: return "waveform.path.ecg"
        case .transparency: return "ear.and.waveform"
        case .adaptive: return "sparkles"
        }
    }
}
