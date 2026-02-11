import SwiftUI
import UniformTypeIdentifiers

struct ImportPresetSheet: View {
    @Binding var isPresented: Bool
    let onPresetImported: (CustomEQPreset) -> Void
    
    /// If provided, the sheet is in "Edit Mode" and will update the existing preset.
    var existingPreset: CustomEQPreset?
    
    @State private var presetName: String = ""
    @State private var text: String = ""
    @State private var isImporterPresented: Bool = false
    
    private var isEditMode: Bool { existingPreset != nil }
    
    var body: some View {
        VStack(spacing: 20) {
            Text(isEditMode ? "Edit Preset" : "New Parametric Preset")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Name")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("My Custom Preset", text: $presetName)
                    .textFieldStyle(.roundedBorder)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Configuration")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(8)
                    .frame(minHeight: 150)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                
                Text("Format: 'Filter 1: ON PK Fc 100 Hz Gain -3.0 dB Q 2.0'")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("If you are using AutoEQ use the SoundSource preset")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            HStack {
                Button(action: { isImporterPresented = true }) {
                    Label("Load from File...", systemImage: "doc")
                }
                .buttonStyle(.bordered)
                
                Spacer()
            }
            
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.escape)
                
                Spacer()
                
                Button(isEditMode ? "Save Changes" : "Save Preset") {
                    saveAndDismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(presetName.isEmpty || text.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 450, height: 500)
        .onAppear {
            // Pre-populate fields if editing an existing preset
            if let preset = existingPreset {
                presetName = preset.name
                text = preset.configurationText
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.text, .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
    }
    
    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            // Security: access security scoped resource
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            
            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                self.text = content
                
                // Default name to filename if empty
                if presetName.isEmpty {
                    presetName = url.deletingPathExtension().lastPathComponent
                }
            } catch {
                // Log error?
            }
        case .failure:
            break
        }
    }
    
    private func saveAndDismiss() {
        let (preamp, bands) = EQSettings.parseParametricText(text)
        
        let presetToSave: CustomEQPreset
        if let existing = existingPreset {
            // Update existing preset (keep same UUID)
            presetToSave = CustomEQPreset(
                id: existing.id,
                name: presetName,
                preampGain: preamp,
                bands: bands
            )
        } else {
            // Create new preset
            presetToSave = CustomEQPreset(
                name: presetName,
                preampGain: preamp,
                bands: bands
            )
        }
        
        // Save to storage
        PresetManager.shared.savePreset(presetToSave)
        
        // Callback
        onPresetImported(presetToSave)
        isPresented = false
    }
}
