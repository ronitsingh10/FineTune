import Foundation
import SwiftUI

enum FilterType: String, Codable, CaseIterable, Identifiable {
    case peak
    case lowShelf
    case highShelf
    
    var id: String { rawValue }
    
    var name: String {
        switch self {
        case .peak: return "Peaking"
        case .lowShelf: return "Low Shelf"
        case .highShelf: return "High Shelf"
        }
    }
    
    var abbreviation: String {
        switch self {
        case .peak: return "PK"
        case .lowShelf: return "LS"
        case .highShelf: return "HS"
        }
    }
}
