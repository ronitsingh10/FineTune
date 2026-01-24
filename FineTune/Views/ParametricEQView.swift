import SwiftUI

struct ParametricEQView: View {
    @Binding var settings: EQSettings
    let onSettingsChanged: (EQSettings) -> Void
    
    @State private var importText: String = ""
    @State private var isImporting: Bool = false
    
    var body: some View {
        VStack(spacing: 12) {
            // Header / Controls
            HStack {
                Text("\(settings.parametricBands.count) Bands")
                    .font(DesignTokens.Typography.pickerText)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
                
                Spacer()
                
                Button(action: { isImporting = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                        Text("Import")
                    }
                    .font(DesignTokens.Typography.pickerText)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }
            .padding(.horizontal, 4)
            
            // Bands List
            if settings.parametricBands.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 24))
                        .foregroundColor(DesignTokens.Colors.textTertiary)
                    Text("No bands loaded")
                        .font(DesignTokens.Typography.caption)
                        .foregroundColor(DesignTokens.Colors.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.1))
                .cornerRadius(4)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 4) {
                        ForEach(settings.parametricBands) { band in
                            HStack(spacing: 8) {
                                Text(band.type.abbreviation)
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .frame(width: 20, alignment: .leading)
                                    .foregroundColor(DesignTokens.Colors.textSecondary)
                                
                                Text("\(Int(band.frequency))Hz")
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 50, alignment: .trailing)
                                
                                Text(String(format: "%+.1fdB", band.gain))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(band.gain > 0 ? .green : (band.gain < 0 ? .red : .primary))
                                    .frame(width: 50, alignment: .trailing)
                                
                                Text("Q: \(String(format: "%.2f", band.Q))")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(DesignTokens.Colors.textTertiary)
                                    .frame(width: 50, alignment: .trailing)
                                
                                Spacer()
                                
                                Toggle("", isOn: Binding(
                                    get: { band.isEnabled },
                                    set: { val in
                                        if let idx = settings.parametricBands.firstIndex(where: { $0.id == band.id }) {
                                            settings.parametricBands[idx].isEnabled = val
                                            onSettingsChanged(settings)
                                        }
                                    }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .scaleEffect(0.6)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(Color.white.opacity(0.03))
                            .cornerRadius(4)
                        }
                    }
                }
                .frame(height: 120) // Fixed height to match somewhat with the sliders area
            }
        }
        .sheet(isPresented: $isImporting) {
            ImportSheet(settings: $settings, onSettingsChanged: onSettingsChanged, isPresented: $isImporting)
        }
    }
}

struct ImportSheet: View {
    @Binding var settings: EQSettings
    let onSettingsChanged: (EQSettings) -> Void
    @Binding var isPresented: Bool
    @State private var text: String = ""
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Import Parametric EQ")
                .font(.headline)
            
            Text("Paste settings in format:\n'Filter 1: ON LS Fc 105.0 Hz Gain 11.2 dB Q 0.70'")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Color.white.opacity(0.1))
                .cornerRadius(8)
                .frame(minHeight: 200)
            
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.plain)
                .foregroundColor(.red)
                
                Spacer()
                
                Button("Apply") {
                    let (preamp, bands) = EQSettings.parseParametricText(text)
                    settings.preampGain = preamp
                    settings.parametricBands = bands
                    onSettingsChanged(settings)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 400, height: 400)
    }
}
