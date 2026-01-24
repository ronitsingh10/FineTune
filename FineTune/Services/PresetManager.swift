import Foundation
import os

@MainActor
class PresetManager: ObservableObject {
    
    static let shared = PresetManager()
    private let logger = Logger(subsystem: "com.finetune", category: "PresetManager")
    
    @Published var presets: [CustomEQPreset] = []
    
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    private var dataFolder: URL? {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return appSupport.appendingPathComponent("FineTune/EQPresets")
    }
    
    private init() {
        // Create directory if needed
        if let folder = dataFolder {
            try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        loadPresets()
    }
    
    func loadPresets() {
        guard let folder = dataFolder else { return }
        
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            var loaded: [CustomEQPreset] = []
            
            for url in fileURLs where url.pathExtension == "json" {
                if let data = try? Data(contentsOf: url),
                   let preset = try? decoder.decode(CustomEQPreset.self, from: data) {
                    loaded.append(preset)
                }
            }
            // Sort by name
            self.presets = loaded.sorted { $0.name < $1.name }
        } catch {
            logger.error("Failed to load presets: \(error.localizedDescription)")
        }
    }
    
    func savePreset(_ preset: CustomEQPreset) {
        guard let folder = dataFolder else { return }
        let url = folder.appendingPathComponent("\(preset.id.uuidString).json")
        
        do {
            let data = try encoder.encode(preset)
            try data.write(to: url)
            
            // Update in-memory list
            if let index = presets.firstIndex(where: { $0.id == preset.id }) {
                presets[index] = preset
            } else {
                presets.append(preset)
                presets.sort { $0.name < $1.name }
            }
        } catch {
            logger.error("Failed to save preset: \(error.localizedDescription)")
        }
    }
    
    func deletePreset(_ preset: CustomEQPreset) {
        guard let folder = dataFolder else { return }
        let url = folder.appendingPathComponent("\(preset.id.uuidString).json")
        
        try? fileManager.removeItem(at: url)
        presets.removeAll { $0.id == preset.id }
    }
}
