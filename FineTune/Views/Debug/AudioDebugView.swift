// FineTune/Views/Debug/AudioDebugView.swift
// Real-time audio routing debug panel for FineTune

import SwiftUI
import Combine

/// Floating debug panel showing real-time audio routing state.
/// Shows per-app tap status, device routing, audio levels, and loopback state.
struct AudioDebugView: View {
    let audioEngine: AudioEngine

    @State private var refreshTick = 0
    @State private var selectedAppPID: pid_t? = nil
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header & App Selector
                headerSection
                
                if let appInfo = selectedAppInfo {
                    // 1. Visual Routing Diagram
                    routingDiagramSection(appInfo)
                    
                    // 2. Sample Rate Chain View
                    sampleRateChainSection(appInfo)
                    
                    // 3. IO Callback Stats Card
                    ioStatsCard(appInfo)
                    
                    // 4. Per-Output Signal Card
                    outputSignalCard(appInfo)
                } else {
                    noAppSelectedView
                }
                
                // 5. Ring Buffer Card (Global / Loopback diagnostics)
                loopbackCard
            }
            .padding(16)
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 500, idealHeight: 750)
        .darkGlassBackground()
        .onReceive(timer) { _ in
            refreshTick += 1
            // Auto-select first app if none selected
            let infos = audioEngine.debugTapInfos
            if selectedAppPID == nil, let first = infos.first {
                selectedAppPID = first.pid
            } else if let currentPID = selectedAppPID, !infos.contains(where: { $0.pid == currentPID }) {
                // If selected app disappeared, fallback to first
                selectedAppPID = infos.first?.pid
            }
        }
    }

    // MARK: - Header & Selector

    private var headerSection: some View {
        HStack {
            Image(systemName: "terminal.fill")
                .vibrancyIcon(.primary)
                .font(.title2)
            Text("FineTune Diagnostics")
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
            
            Spacer()
            
            let infos = audioEngine.debugTapInfos
            if !infos.isEmpty {
                Picker("Inspect App:", selection: $selectedAppPID) {
                    ForEach(infos, id: \.pid) { info in
                        Text("\(info.appName) (PID \(info.pid))")
                            .tag(info.pid as pid_t?)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 220)
            }
        }
        .padding(.bottom, 8)
    }

    private var noAppSelectedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.exclamationmark")
                .font(.largeTitle)
                .vibrancyIcon(.tertiary)
            Text("No active audio apps or taps found")
                .font(.headline)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
            Text("Open an app configured in FineTune and play audio to begin diagnostics.")
                .font(.subheadline)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .eqCardBackground()
    }

    private var selectedAppInfo: AudioEngine.TapDebugInfo? {
        audioEngine.debugTapInfos.first(where: { $0.pid == selectedAppPID }) ?? audioEngine.debugTapInfos.first
    }

    // MARK: - Visual Routing Diagram

    @ViewBuilder
    private func routingDiagramSection(_ info: AudioEngine.TapDebugInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Audio Signal Routing")
                .sectionHeaderStyle()
            
            VStack(spacing: 0) {
                // Top Row: App -> Tap -> Aggregate
                HStack(alignment: .center, spacing: 0) {
                    // Node 1: App
                    DiagnosticNode(
                        title: info.appName,
                        subtitle: "PID \(info.pid)",
                        icon: "app.window.description",
                        statusColor: info.audioLevel > 0.01 ? .green : .orange
                    ) {
                        HStack {
                            Text(info.bundleID ?? "no bundle ID")
                                .font(.system(size: 8))
                                .foregroundStyle(DesignTokens.Colors.textTertiary)
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                    
                    ConnectorArrow(direction: .right)
                    
                    // Node 2: Process Tap
                    let isMutedText = info.isMuted ? "muted" : "unmuted"
                    let captureText = info.isUnmutedCapture ? "passthrough" : "controlled"
                    DiagnosticNode(
                        title: "Process Tap",
                        subtitle: String(format: "%.1f kHz", info.sampleRate / 1000.0),
                        icon: "waveform.path",
                        statusColor: info.ioStats != nil ? .green : .orange
                    ) {
                        HStack {
                            Text("\(isMutedText) • \(captureText)")
                                .font(.system(size: 8))
                                .foregroundStyle(info.isMuted ? Color.orange : Color.green)
                            Spacer()
                        }
                    }
                    
                    ConnectorArrow(direction: .right)
                    
                    // Node 3: Aggregate Output Device
                    let deviceName = info.deviceUID.flatMap {
                        audioEngine.deviceMonitor.device(for: $0)?.name
                    } ?? "None"
                    DiagnosticNode(
                        title: "Aggregate Out",
                        subtitle: deviceName,
                        icon: "speaker.wave.2.fill"
                    ) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(info.deviceUIDs, id: \.self) { uid in
                                let name = audioEngine.deviceMonitor.device(for: uid)?.name ?? uid
                                HStack(spacing: 4) {
                                    Text("▸")
                                        .font(.caption)
                                        .foregroundStyle(DesignTokens.Colors.accentPrimary)
                                    Text(name)
                                        .font(.system(size: 8))
                                        .lineLimit(1)
                                    Spacer()
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 4, height: 4)
                                }
                            }
                        }
                    }
                }
                
                // Down connection from Tap
                HStack(spacing: 0) {
                    Spacer().frame(width: 170 + 30 + 85) // align to center of Tap Node
                    ConnectorArrow(direction: .down)
                    Spacer()
                }
                
                // Bottom Row: Ring Buffer -> Ableton
                HStack(alignment: .center, spacing: 0) {
                    Spacer().frame(width: 170 + 30) // App node width + arrow
                    
                    let loopbackInfo = audioEngine.debugLoopbackInfo
                    let ringStats = loopbackInfo.bufferStats
                    let isBufferActive = loopbackInfo.isActive && info.isLoopbackEnabled
                    
                    // Node 4: Ring Buffer
                    DiagnosticNode(
                        title: "Ring Buffer",
                        subtitle: ringStats != nil ? String(format: "%.1f kHz", ringStats!.sampleRate / 1000.0) : "Offline",
                        icon: "arrow.triangle.2.circlepath",
                        statusColor: isBufferActive ? .green : .orange
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            if let stats = ringStats, info.isLoopbackEnabled {
                                Text(String(format: "%.0f%% full", stats.fillLevel * 100))
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(stats.isOverrun ? .red : (stats.isUnderrun ? .orange : .green))
                            } else {
                                Text("disabled")
                                    .font(.system(size: 8))
                                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                            }
                        }
                    }
                    
                    ConnectorArrow(direction: .right)
                    
                    // Node 5: Ableton / DAW
                    DiagnosticNode(
                        title: "DAW (Ableton)",
                        subtitle: "Virtual Input",
                        icon: "waveform.circle",
                        statusColor: isBufferActive ? .green : .secondary
                    ) {
                        HStack {
                            Text(isBufferActive ? "Receiving Loopback" : "Idle / Stopped")
                                .font(.system(size: 8))
                                .foregroundStyle(isBufferActive ? .green : .secondary)
                            Spacer()
                        }
                    }
                    
                    Spacer() // fill remainder to keep layout balanced
                }
            }
        }
    }

    // MARK: - Sample Rate Chain View

    @ViewBuilder
    private func sampleRateChainSection(_ info: AudioEngine.TapDebugInfo) -> some View {
        let appSR = info.sampleRate
        let tapSR = info.sampleRate
        let aggSR = info.deviceSampleRate
        
        let loopbackInfo = audioEngine.debugLoopbackInfo
        let bufferSR = loopbackInfo.bufferStats?.sampleRate ?? 0.0
        
        let hasMismatch = info.sampleRateMismatch || (info.isLoopbackEnabled && bufferSR > 0 && abs(aggSR - bufferSR) > 0.1)
        
        VStack(alignment: .leading, spacing: 6) {
            Text("Sample Rate Chain")
                .sectionHeaderStyle()
            
            HStack(spacing: 8) {
                VStack(spacing: 4) {
                    Text("App Source")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                    Text(appSR > 0 ? String(format: "%.1f kHz", appSR / 1000.0) : "Auto")
                        .font(.system(size: 11, design: .monospaced))
                }
                
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                
                VStack(spacing: 4) {
                    Text("Process Tap")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                    Text(tapSR > 0 ? String(format: "%.1f kHz", tapSR / 1000.0) : "Unknown")
                        .font(.system(size: 11, design: .monospaced))
                }
                
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                
                VStack(spacing: 4) {
                    Text("Aggregate")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                    Text(aggSR > 0 ? String(format: "%.1f kHz", aggSR / 1000.0) : "Offline")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(info.sampleRateMismatch ? Color.red : Color.primary)
                }
                
                if info.isLoopbackEnabled {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                    
                    VStack(spacing: 4) {
                        Text("Ring Buffer")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(DesignTokens.Colors.textSecondary)
                        Text(bufferSR > 0 ? String(format: "%.1f kHz", bufferSR / 1000.0) : "Offline")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle((bufferSR > 0 && abs(aggSR - bufferSR) > 0.1) ? Color.red : Color.primary)
                    }
                }
                
                Spacer()
                
                if hasMismatch {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text("SR MISMATCH")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.red)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.red.opacity(0.15))
                    .cornerRadius(4)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("ALIGNED")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.green)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.15))
                    .cornerRadius(4)
                }
            }
            .padding(10)
            .eqCardBackground()
        }
    }

    // MARK: - IO Callback Stats Card

    @ViewBuilder
    private func ioStatsCard(_ info: AudioEngine.TapDebugInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("IO Callback Metrics", systemImage: "clock.fill")
                .font(DesignTokens.Typography.cardHeader)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
            
            if let stats = info.ioStats {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        metricRow("Callbacks Fired", "\(stats.callbackCount)")
                        metricRow("Callbacks / Sec", String(format: "%.2f Hz", stats.callbacksPerSecond))
                        metricRow("Frames / Callback", String(format: "%.1f", stats.framesPerCallback))
                        metricRow("Total Frames", "\(stats.totalFrames)")
                    }
                    
                    Spacer()
                    Divider()
                    Spacer()
                    
                    VStack(alignment: .leading, spacing: 6) {
                        metricRow("Last Callback", stats.lastCallbackAgo == Double.infinity ? "never" : String(format: "%.3f s ago", stats.lastCallbackAgo))
                        
                        let level = stats.inputPeak
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Input Peak Level")
                                .font(.system(size: 10))
                                .foregroundStyle(DesignTokens.Colors.textSecondary)
                            HStack {
                                VUMeterView(level: level, isMuted: info.isMuted)
                                Text(String(format: "%.2f", level))
                                    .font(.system(size: 10, design: .monospaced))
                                    .frame(width: 32, alignment: .trailing)
                            }
                        }
                    }
                }
            } else {
                Text("No IO callback stats recorded. Play audio to start callback metrics.")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
        }
        .padding(16)
        .eqCardBackground()
    }
    
    @ViewBuilder
    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .fontWeight(.medium)
        }
    }

    // MARK: - Per-Output Signal Card

    @ViewBuilder
    private func outputSignalCard(_ info: AudioEngine.TapDebugInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Sub-Device Outputs", systemImage: "speaker.wave.2.fill")
                .font(DesignTokens.Typography.cardHeader)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
            
            if info.deviceUIDs.isEmpty {
                Text("No output aggregate sub-devices connected.")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(0..<info.deviceUIDs.count, id: \.self) { index in
                        let uid = info.deviceUIDs[index]
                        let name = audioEngine.deviceMonitor.device(for: uid)?.name ?? uid
                        
                        let subDevice = audioEngine.deviceMonitor.device(for: uid)
                        let subSampleRate = (try? subDevice?.id.readNominalSampleRate()) ?? 0.0
                        
                        let isMismatch = subSampleRate > 0 && info.sampleRate > 0 && abs(subSampleRate - info.sampleRate) > 0.1
                        
                        let peak = info.ioStats?.outputPeaks[safe: index] ?? 0.0
                        
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(name)
                                        .font(.system(size: 11, weight: .semibold))
                                    Text(uid)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                                }
                                
                                Spacer()
                                
                                VStack(alignment: .trailing, spacing: 1) {
                                    HStack(spacing: 4) {
                                        Text(subSampleRate > 0 ? String(format: "%.1f kHz", subSampleRate / 1000.0) : "Offline")
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(isMismatch ? Color.red : DesignTokens.Colors.textSecondary)
                                        
                                        if isMismatch {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .font(.system(size: 9))
                                                .foregroundStyle(.red)
                                        }
                                    }
                                    
                                    Text(isMismatch ? "Mismatch" : "Aligned")
                                        .font(.system(size: 8))
                                        .foregroundStyle(isMismatch ? Color.red : Color.green)
                                }
                            }
                            
                            HStack {
                                VUMeterView(level: peak, isMuted: info.isMuted)
                                Text(String(format: "%.2f", peak))
                                    .font(.system(size: 9, design: .monospaced))
                                    .frame(width: 32, alignment: .trailing)
                            }
                        }
                        .padding(8)
                        .background(DesignTokens.Colors.recessedBackground)
                        .cornerRadius(6)
                    }
                }
            }
        }
        .padding(16)
        .eqCardBackground()
    }

    // MARK: - Ring Buffer Card

    @ViewBuilder
    private var loopbackCard: some View {
        let info = audioEngine.debugLoopbackInfo
        
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .vibrancyIcon(.primary)
                Text("Loopback Ring Buffer Diagnostics")
                    .font(DesignTokens.Typography.cardHeader)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                Spacer()
                if info.isActive {
                    Text("🟢 ACTIVE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.green)
                } else {
                    Text("⚪ INACTIVE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            
            if !info.isDriverInstalled {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("FineTune Loopback driver is not installed.")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                }
                .padding(10)
                .background(Color.red.opacity(0.1))
                .cornerRadius(6)
            } else if let stats = info.bufferStats {
                HStack(spacing: 20) {
                    // Gauge representation
                    VStack(spacing: 4) {
                        ZStack {
                            Circle()
                                .stroke(DesignTokens.Colors.sliderTrack, lineWidth: 6)
                                .frame(width: 60, height: 60)
                            Circle()
                                .trim(from: 0, to: CGFloat(min(max(stats.fillLevel, 0), 1)))
                                .stroke(stats.isOverrun ? Color.red : (stats.isUnderrun ? Color.orange : DesignTokens.Colors.accentPrimary), lineWidth: 6)
                                .rotationEffect(.degrees(-90))
                                .frame(width: 60, height: 60)
                                .animation(.spring(), value: stats.fillLevel)
                            
                            Text(String(format: "%.0f%%", stats.fillLevel * 100))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        Text("Fill Level")
                            .font(.system(size: 9))
                            .foregroundStyle(DesignTokens.Colors.textSecondary)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Write Head:")
                                .font(.system(size: 10))
                                .foregroundStyle(DesignTokens.Colors.textSecondary)
                            Spacer()
                            Text("\(stats.writeHead)")
                                .font(.system(size: 10, design: .monospaced))
                        }
                        HStack {
                            Text("Read Head:")
                                .font(.system(size: 10))
                                .foregroundStyle(DesignTokens.Colors.textSecondary)
                            Spacer()
                            Text("\(stats.readHead)")
                                .font(.system(size: 10, design: .monospaced))
                        }
                        HStack {
                            Text("Buffer Frames:")
                                .font(.system(size: 10))
                                .foregroundStyle(DesignTokens.Colors.textSecondary)
                            Spacer()
                            Text("\(stats.bufferFrames) frames")
                                .font(.system(size: 10, design: .monospaced))
                        }
                        HStack {
                            Text("Sample Rate:")
                                .font(.system(size: 10))
                                .foregroundStyle(DesignTokens.Colors.textSecondary)
                            Spacer()
                            Text(String(format: "%.1f kHz", stats.sampleRate / 1000.0))
                                .font(.system(size: 10, design: .monospaced))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    
                    VStack(spacing: 8) {
                        if stats.isOverrun {
                            Label("OVERRUN", systemImage: "exclamationmark.octagon.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.red.opacity(0.1))
                                .cornerRadius(4)
                        }
                        if stats.isUnderrun {
                            Label("UNDERRUN", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.orange.opacity(0.1))
                                .cornerRadius(4)
                        }
                        
                        if !stats.isOverrun && !stats.isUnderrun {
                            Label("HEALTHY", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.green.opacity(0.1))
                                .cornerRadius(4)
                        }
                    }
                }
            } else {
                Text("Loopback ring buffer is currently inactive/unallocated.")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
        }
        .padding(16)
        .eqCardBackground()
    }
}

// MARK: - Diagnostic Node Component

struct DiagnosticNode<Content: View>: View {
    let title: String
    let subtitle: String?
    let icon: String
    let statusColor: Color
    let content: Content
    
    init(title: String, subtitle: String? = nil, icon: String, statusColor: Color = .green, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.statusColor = statusColor
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .vibrancyIcon(.primary)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .lineLimit(1)
                Spacer()
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .lineLimit(1)
            }
            content
        }
        .padding(10)
        .frame(width: 170, height: 80)
        .eqCardBackground()
    }
}

// MARK: - Connector Arrow Component

struct ConnectorArrow: View {
    let direction: Direction
    
    enum Direction {
        case right, down
    }
    
    var body: some View {
        Group {
            if direction == .right {
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(DesignTokens.Colors.textTertiary.opacity(0.5))
                        .frame(height: 1.5)
                    Image(systemName: "play.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(DesignTokens.Colors.textTertiary.opacity(0.5))
                        .offset(x: -2)
                }
                .frame(width: 30)
            } else {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(DesignTokens.Colors.textTertiary.opacity(0.5))
                        .frame(width: 1.5, height: 25)
                    Image(systemName: "triangle.fill")
                        .font(.system(size: 8))
                        .rotationEffect(.degrees(180))
                        .foregroundStyle(DesignTokens.Colors.textTertiary.opacity(0.5))
                        .offset(y: -2)
                }
            }
        }
    }
}

// MARK: - Professional Audio VU Meter

struct VUMeterView: View {
    let level: Float
    let isMuted: Bool
    
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<8) { index in
                let threshold = Float(index) / 8.0
                let isLit = level > threshold
                
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(colorForSegment(index, isLit: isLit))
                    .frame(height: 6)
            }
        }
    }
    
    private func colorForSegment(_ index: Int, isLit: Bool) -> Color {
        guard isLit else { return DesignTokens.Colors.vuUnlit }
        if isMuted { return DesignTokens.Colors.vuMuted }
        
        switch index {
        case 0...3: return DesignTokens.Colors.vuGreen
        case 4...5: return DesignTokens.Colors.vuYellow
        case 6: return DesignTokens.Colors.vuOrange
        default: return DesignTokens.Colors.vuRed
        }
    }
}

// MARK: - Safe Subscript Extension

extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Debug Window Controller

@MainActor
final class AudioDebugWindowController {
    static let shared = AudioDebugWindowController()
    private var window: NSWindow?

    func showWindow(audioEngine: AudioEngine) {
        if let existing = window, existing.isVisible {
            existing.orderFrontRegardless()
            return
        }

        let debugView = AudioDebugView(audioEngine: audioEngine)
        let hostingView = NSHostingView(rootView: debugView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 700, height: 750)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 750),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "FineTune Diagnostics"
        panel.contentView = hostingView
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.center()
        panel.orderFrontRegardless()

        self.window = panel
    }
}
