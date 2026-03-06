// FineTune/Audio/EQProcessor.swift
import Foundation
import Accelerate
import os

/// RT-safe EQ processor with two serial stages:
/// 1) Headphone EQ (AutoEQ parametric filters)
/// 2) Graphic EQ (10 fixed bands)
final class EQProcessor: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.finetune.audio", category: "EQProcessor")

    /// Number of delay samples per channel for 10-band graphic EQ: (2 * sections) + 2
    private static let graphicDelayBufferSize = (2 * EQSettings.bandCount) + 2

    private var sampleRate: Double

    // Persisted settings snapshot (main thread only)
    private var _currentGraphicSettings: EQSettings = .flat
    private var _currentHeadphoneSettings: HeadphoneEQSettings = .empty

    // Lock-free state for RT-safe access
    private nonisolated(unsafe) var _graphicSetup: vDSP_biquad_Setup?
    private nonisolated(unsafe) var _headphoneSetup: vDSP_biquad_Setup?
    private nonisolated(unsafe) var _isGraphicEnabled: Bool = false
    private nonisolated(unsafe) var _isHeadphoneEnabled: Bool = false

    /// Pre-EQ attenuation to prevent clipping when boosted filters are enabled.
    private nonisolated(unsafe) var _preampAttenuation: Float = 1.0

    // Graphic EQ delay buffers (fixed 10-section topology)
    private let graphicDelayBufferL: UnsafeMutablePointer<Float>
    private let graphicDelayBufferR: UnsafeMutablePointer<Float>

    // Headphone EQ delay buffers (dynamic section count)
    private nonisolated(unsafe) var _headphoneDelayBufferL: UnsafeMutablePointer<Float>?
    private nonisolated(unsafe) var _headphoneDelayBufferR: UnsafeMutablePointer<Float>?
    private nonisolated(unsafe) var _headphoneDelayBufferCount: Int = 0

    /// Whether any EQ stage is enabled.
    var isEnabled: Bool {
        _isGraphicEnabled || _isHeadphoneEnabled
    }

    /// Pre-EQ gain reduction to prevent clipping (RT-safe read).
    var preampAttenuation: Float { _preampAttenuation }

    init(sampleRate: Double) {
        self.sampleRate = sampleRate

        // Allocate fixed graphic delay buffers once.
        graphicDelayBufferL = UnsafeMutablePointer<Float>.allocate(capacity: Self.graphicDelayBufferSize)
        graphicDelayBufferL.initialize(repeating: 0, count: Self.graphicDelayBufferSize)

        graphicDelayBufferR = UnsafeMutablePointer<Float>.allocate(capacity: Self.graphicDelayBufferSize)
        graphicDelayBufferR.initialize(repeating: 0, count: Self.graphicDelayBufferSize)

        // Initialize stages with defaults.
        updateSettings(.flat)
        updateHeadphoneSettings(.empty)
    }

    deinit {
        if let setup = _graphicSetup {
            vDSP_biquad_DestroySetup(setup)
        }
        if let setup = _headphoneSetup {
            vDSP_biquad_DestroySetup(setup)
        }

        graphicDelayBufferL.deallocate()
        graphicDelayBufferR.deallocate()

        _headphoneDelayBufferL?.deallocate()
        _headphoneDelayBufferR?.deallocate()
    }

    /// Updates 10-band graphic EQ settings (main thread).
    func updateSettings(_ settings: EQSettings) {
        _currentGraphicSettings = settings
        _isGraphicEnabled = settings.isEnabled

        let coefficients = BiquadMath.coefficientsForAllBands(
            gains: settings.clampedGains,
            sampleRate: sampleRate
        )

        let newSetup = coefficients.withUnsafeBufferPointer { ptr in
            vDSP_biquad_CreateSetup(ptr.baseAddress!, vDSP_Length(EQSettings.bandCount))
        }

        swapGraphicSetup(newSetup)
        recomputePreampAttenuation()
    }

    /// Updates headphone AutoEQ settings (main thread).
    func updateHeadphoneSettings(_ settings: HeadphoneEQSettings) {
        _currentHeadphoneSettings = settings

        let shouldEnable = settings.isEnabled && !settings.filters.isEmpty
        _isHeadphoneEnabled = shouldEnable

        guard shouldEnable else {
            swapHeadphoneResources(setup: nil, delayL: nil, delayR: nil, delayCount: 0)
            recomputePreampAttenuation()
            return
        }

        let coefficients = BiquadMath.coefficientsForParametricFilters(
            filters: settings.filters,
            sampleRate: sampleRate
        )

        guard !coefficients.isEmpty else {
            _isHeadphoneEnabled = false
            swapHeadphoneResources(setup: nil, delayL: nil, delayR: nil, delayCount: 0)
            recomputePreampAttenuation()
            return
        }

        let sectionCount = max(1, coefficients.count / 5)
        let newSetup = coefficients.withUnsafeBufferPointer { ptr in
            vDSP_biquad_CreateSetup(ptr.baseAddress!, vDSP_Length(sectionCount))
        }

        let delayCount = (2 * sectionCount) + 2
        let newDelayL = UnsafeMutablePointer<Float>.allocate(capacity: delayCount)
        newDelayL.initialize(repeating: 0, count: delayCount)

        let newDelayR = UnsafeMutablePointer<Float>.allocate(capacity: delayCount)
        newDelayR.initialize(repeating: 0, count: delayCount)

        swapHeadphoneResources(setup: newSetup, delayL: newDelayL, delayR: newDelayR, delayCount: delayCount)
        recomputePreampAttenuation()
    }

    /// Updates sample rate and rebuilds all stage coefficients.
    /// Safe to call on main thread during device switches.
    func updateSampleRate(_ newRate: Double) {
        dispatchPrecondition(condition: .onQueue(.main))

        let oldRate = sampleRate
        guard newRate != oldRate else { return }
        sampleRate = newRate
        logger.info("[EQ] Sample rate updated: \(oldRate, format: .fixed(precision: 0))Hz → \(newRate, format: .fixed(precision: 0))Hz")

        let restoreGraphicEnabled = _isGraphicEnabled
        let restoreHeadphoneEnabled = _isHeadphoneEnabled

        // Temporarily disable processing while rebuilding setups and clearing delay state.
        _isGraphicEnabled = false
        _isHeadphoneEnabled = false
        OSMemoryBarrier()

        // Rebuild graphic stage.
        let graphicCoefficients = BiquadMath.coefficientsForAllBands(
            gains: _currentGraphicSettings.clampedGains,
            sampleRate: newRate
        )
        let newGraphicSetup = graphicCoefficients.withUnsafeBufferPointer { ptr in
            vDSP_biquad_CreateSetup(ptr.baseAddress!, vDSP_Length(EQSettings.bandCount))
        }
        swapGraphicSetup(newGraphicSetup)

        // Rebuild headphone stage if a profile exists.
        if !_currentHeadphoneSettings.filters.isEmpty {
            let hpCoefficients = BiquadMath.coefficientsForParametricFilters(
                filters: _currentHeadphoneSettings.filters,
                sampleRate: newRate
            )

            if hpCoefficients.isEmpty {
                swapHeadphoneResources(setup: nil, delayL: nil, delayR: nil, delayCount: 0)
            } else {
                let sectionCount = max(1, hpCoefficients.count / 5)
                let newHeadphoneSetup = hpCoefficients.withUnsafeBufferPointer { ptr in
                    vDSP_biquad_CreateSetup(ptr.baseAddress!, vDSP_Length(sectionCount))
                }
                let delayCount = (2 * sectionCount) + 2
                let newDelayL = UnsafeMutablePointer<Float>.allocate(capacity: delayCount)
                newDelayL.initialize(repeating: 0, count: delayCount)
                let newDelayR = UnsafeMutablePointer<Float>.allocate(capacity: delayCount)
                newDelayR.initialize(repeating: 0, count: delayCount)
                swapHeadphoneResources(
                    setup: newHeadphoneSetup,
                    delayL: newDelayL,
                    delayR: newDelayR,
                    delayCount: delayCount
                )
            }
        } else {
            swapHeadphoneResources(setup: nil, delayL: nil, delayR: nil, delayCount: 0)
        }

        // Reset stage delay state.
        memset(graphicDelayBufferL, 0, Self.graphicDelayBufferSize * MemoryLayout<Float>.size)
        memset(graphicDelayBufferR, 0, Self.graphicDelayBufferSize * MemoryLayout<Float>.size)

        if let hpDelayL = _headphoneDelayBufferL,
           let hpDelayR = _headphoneDelayBufferR,
           _headphoneDelayBufferCount > 0 {
            memset(hpDelayL, 0, _headphoneDelayBufferCount * MemoryLayout<Float>.size)
            memset(hpDelayR, 0, _headphoneDelayBufferCount * MemoryLayout<Float>.size)
        }

        _isGraphicEnabled = restoreGraphicEnabled
        _isHeadphoneEnabled = restoreHeadphoneEnabled && !_currentHeadphoneSettings.filters.isEmpty && _headphoneSetup != nil
        recomputePreampAttenuation()
        OSMemoryBarrier()
    }

    /// Process stereo interleaved audio in-place (RT-safe).
    /// - Parameters:
    ///   - input: Input buffer (stereo interleaved Float32)
    ///   - output: Output buffer (stereo interleaved Float32)
    ///   - frameCount: Number of stereo frames (samples / 2)
    func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int) {
        let graphicEnabled = _isGraphicEnabled
        let headphoneEnabled = _isHeadphoneEnabled

        let graphicSetup = _graphicSetup
        let headphoneSetup = _headphoneSetup
        let headphoneDelayL = _headphoneDelayBufferL
        let headphoneDelayR = _headphoneDelayBufferR

        // Bypass: copy input to output if needed.
        if input != UnsafePointer(output) {
            memcpy(output, input, frameCount * 2 * MemoryLayout<Float>.size)
        }

        guard graphicEnabled || headphoneEnabled else {
            return
        }

        if headphoneEnabled,
           let hpSetup = headphoneSetup,
           let hpDelayL = headphoneDelayL,
           let hpDelayR = headphoneDelayR {
            vDSP_biquad(
                hpSetup,
                hpDelayL,
                output,
                2,
                output,
                2,
                vDSP_Length(frameCount)
            )

            vDSP_biquad(
                hpSetup,
                hpDelayR,
                output.advanced(by: 1),
                2,
                output.advanced(by: 1),
                2,
                vDSP_Length(frameCount)
            )
        }

        if graphicEnabled, let gSetup = graphicSetup {
            vDSP_biquad(
                gSetup,
                graphicDelayBufferL,
                output,
                2,
                output,
                2,
                vDSP_Length(frameCount)
            )

            vDSP_biquad(
                gSetup,
                graphicDelayBufferR,
                output.advanced(by: 1),
                2,
                output.advanced(by: 1),
                2,
                vDSP_Length(frameCount)
            )
        }
    }

    // MARK: - Resource Swaps

    private func swapGraphicSetup(_ newSetup: vDSP_biquad_Setup?) {
        let oldSetup = _graphicSetup
        _graphicSetup = newSetup
        scheduleCleanup(setup: oldSetup)
    }

    private func swapHeadphoneResources(
        setup newSetup: vDSP_biquad_Setup?,
        delayL newDelayL: UnsafeMutablePointer<Float>?,
        delayR newDelayR: UnsafeMutablePointer<Float>?,
        delayCount newDelayCount: Int
    ) {
        let oldSetup = _headphoneSetup
        let oldDelayL = _headphoneDelayBufferL
        let oldDelayR = _headphoneDelayBufferR

        _headphoneSetup = newSetup
        _headphoneDelayBufferL = newDelayL
        _headphoneDelayBufferR = newDelayR
        _headphoneDelayBufferCount = newDelayCount

        scheduleCleanup(setup: oldSetup, delayL: oldDelayL, delayR: oldDelayR)
    }

    private func scheduleCleanup(setup: vDSP_biquad_Setup?) {
        guard let setup else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            vDSP_biquad_DestroySetup(setup)
        }
    }

    private func scheduleCleanup(
        setup: vDSP_biquad_Setup?,
        delayL: UnsafeMutablePointer<Float>?,
        delayR: UnsafeMutablePointer<Float>?
    ) {
        guard setup != nil || delayL != nil || delayR != nil else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            if let setup {
                vDSP_biquad_DestroySetup(setup)
            }
            delayL?.deallocate()
            delayR?.deallocate()
        }
    }

    private func recomputePreampAttenuation() {
        let maxGraphicBoost = _isGraphicEnabled ? (_currentGraphicSettings.clampedGains.max() ?? 0) : 0
        let maxHeadphoneBoost = _isHeadphoneEnabled
            ? (_currentHeadphoneSettings.filters.map(\.gainDB).max() ?? 0)
            : 0
        let maxBoostDB = max(maxGraphicBoost, maxHeadphoneBoost)
        _preampAttenuation = maxBoostDB > 0 ? pow(10.0, -maxBoostDB / 20.0) : 1.0
    }
}
