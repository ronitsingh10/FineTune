import SwiftUI

struct ParametricEQView: View {
    @Binding var settings: EQSettings
    let onSettingsChanged: (EQSettings) -> Void
    
    
    var body: some View {
        VStack(spacing: 12) {
            // Header / Controls
            HStack {
                Text("\(settings.parametricBands.count) Bands")
                    .font(DesignTokens.Typography.pickerText)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
                
                Text("•")
                    .foregroundColor(DesignTokens.Colors.textTertiary)
                
                Text(String(format: "Preamp: %+.1f dB", settings.preampGain))
                    .font(DesignTokens.Typography.pickerText)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
                
                Spacer()
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
        }
    }



