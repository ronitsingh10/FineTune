// FineTune/Audio/AUPlugins/AUEffectHost.swift
import AudioToolbox
import Foundation
import os

/// RT-safe wrapper around a single Audio Unit effect instance.
///
/// ## Threading Model
/// - **Main thread**: instantiation, preset loading, teardown
/// - **HAL I/O thread**: `render()` — RT-safe once the AU is initialized
///
/// ## Audio Format
/// Apple AUs require non-interleaved stereo (separate L/R buffers). Our pipeline
/// uses interleaved stereo (LRLRLR...). This host handles the conversion:
/// deinterleave before AU render, interleave after.
///
/// Follows the same deferred-destroy pattern as `BiquadProcessor`.
final class AUEffectHost: @unchecked Sendable {

    let descriptor: AUPluginDescriptor
    let entryID: UUID

    private nonisolated(unsafe) var _audioUnit: AudioUnit?
    private nonisolated(unsafe) var _isEnabled: Bool
    private nonisolated(unsafe) var _sampleTime: Float64 = 0

    // Pre-allocated deinterleaved buffers for AU rendering (RT-safe).
    // Accessed by the C render callback — must not be private.
    let _bufferL: UnsafeMutablePointer<Float>
    let _bufferR: UnsafeMutablePointer<Float>
    let _bufferCapacity: Int

    /// Pre-allocated AudioBufferList with space for 2 AudioBuffers (non-interleaved stereo).
    /// Swift's AudioBufferList struct only has room for 1 buffer inline, so we heap-allocate
    /// at init time with correct size. RT-safe: no allocation in render path.
    private let _ablPtr: UnsafeMutablePointer<AudioBufferList>

    private(set) var factoryPresets: [(index: Int, name: String)] = []
    private(set) var tailTimeSeconds: Double = 0

    private let logger: Logger
    private let sampleRate: Double
    private let maxFrames: UInt32

    var isEnabled: Bool { _isEnabled }
    var audioUnit: AudioUnit? { _audioUnit }

    init(
        descriptor: AUPluginDescriptor,
        entryID: UUID,
        sampleRate: Double,
        maxFrames: UInt32 = 4096,
        enabled: Bool = true
    ) {
        self.descriptor = descriptor
        self.entryID = entryID
        self.sampleRate = sampleRate
        self.maxFrames = maxFrames
        self._isEnabled = enabled
        self._bufferCapacity = Int(maxFrames)
        self._bufferL = .allocate(capacity: Int(maxFrames))
        self._bufferR = .allocate(capacity: Int(maxFrames))
        self._bufferL.initialize(repeating: 0, count: Int(maxFrames))
        self._bufferR.initialize(repeating: 0, count: Int(maxFrames))

        // Allocate AudioBufferList with space for 2 AudioBuffers.
        // AudioBufferList has 1 inline AudioBuffer; we need room for 1 extra.
        let ablSize = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size
        let ablRaw = UnsafeMutableRawPointer.allocate(byteCount: ablSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        ablRaw.initializeMemory(as: UInt8.self, repeating: 0, count: ablSize)
        self._ablPtr = ablRaw.bindMemory(to: AudioBufferList.self, capacity: 1)

        self.logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "AUEffectHost[\(descriptor.name)]")
    }

    deinit {
        if let au = _audioUnit {
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
        }
        _bufferL.deallocate()
        _bufferR.deallocate()
        _ablPtr.deallocate()
    }

    // MARK: - Instantiation (main thread)

    func instantiate() -> Bool {
        var desc = descriptor.audioComponentDescription
        guard let component = AudioComponentFindNext(nil, &desc) else {
            logger.error("AudioComponent not found for \(self.descriptor.name)")
            return false
        }

        var au: AudioUnit?
        var err = AudioComponentInstanceNew(component, &au)
        guard err == noErr, let au else {
            logger.error("AudioComponentInstanceNew failed: \(err)")
            return false
        }

        // Non-interleaved stereo Float32 — the format all Apple AUs support
        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        err = AudioUnitSetProperty(
            au, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 0,
            &streamFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        if err != noErr {
            logger.warning("Failed to set input stream format: \(err)")
        }

        err = AudioUnitSetProperty(
            au, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output, 0,
            &streamFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        if err != noErr {
            logger.warning("Failed to set output stream format: \(err)")
        }

        var frames = maxFrames
        AudioUnitSetProperty(
            au, kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global, 0,
            &frames, UInt32(MemoryLayout<UInt32>.size)
        )

        var renderCallback = AURenderCallbackStruct(
            inputProc: auRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        err = AudioUnitSetProperty(
            au, kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input, 0,
            &renderCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        if err != noErr {
            logger.error("Failed to set render callback: \(err)")
            AudioComponentInstanceDispose(au)
            return false
        }

        err = AudioUnitInitialize(au)
        if err != noErr {
            logger.error("AudioUnitInitialize failed: \(err)")
            AudioComponentInstanceDispose(au)
            return false
        }

        _audioUnit = au
        loadFactoryPresets()
        queryTailTime()
        logger.info("Instantiated \(self.descriptor.name) at \(self.sampleRate)Hz")
        return true
    }

    // MARK: - Enable/Disable

    func setEnabled(_ enabled: Bool) {
        _isEnabled = enabled
    }

    // MARK: - RT-Safe Rendering

    /// Process interleaved stereo audio through this AU effect.
    /// Deinterleaves input → AU render (non-interleaved) → interleaves output.
    /// All buffers are pre-allocated — no allocations on the RT thread.
    @inline(__always)
    func renderInterleaved(samples: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard _isEnabled, let au = _audioUnit else { return }
        let count = min(frameCount, _bufferCapacity)

        // Deinterleave: LRLRLR... → separate L and R buffers
        for i in 0..<count {
            _bufferL[i] = samples[i * 2]
            _bufferR[i] = samples[i * 2 + 1]
        }

        // Configure pre-allocated 2-buffer AudioBufferList (no stack corruption)
        let byteCount = UInt32(count * MemoryLayout<Float>.size)
        let ablBufs = UnsafeMutableAudioBufferListPointer(_ablPtr)
        _ablPtr.pointee.mNumberBuffers = 2
        ablBufs[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteCount, mData: _bufferL)
        ablBufs[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteCount, mData: _bufferR)

        var flags = AudioUnitRenderActionFlags(rawValue: 0)
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = .sampleTimeValid
        timestamp.mSampleTime = _sampleTime
        _sampleTime += Float64(count)

        let err = AudioUnitRender(au, &flags, &timestamp, 0, UInt32(count), _ablPtr)
        if err != noErr { return }

        // Interleave: separate L and R → LRLRLR...
        for i in 0..<count {
            samples[i * 2] = _bufferL[i]
            samples[i * 2 + 1] = _bufferR[i]
        }
    }

    // MARK: - Presets

    func savePreset() -> Data? {
        guard let au = _audioUnit else { return nil }
        var classInfo: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        let err = AudioUnitGetProperty(
            au, kAudioUnitProperty_ClassInfo,
            kAudioUnitScope_Global, 0,
            &classInfo, &size
        )
        guard err == noErr, let plist = classInfo?.takeRetainedValue() else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    func loadPreset(_ data: Data) -> Bool {
        guard let au = _audioUnit else { return false }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return false }
        let cfPlist = plist as CFPropertyList
        var mutablePlist: CFPropertyList? = cfPlist
        let err = AudioUnitSetProperty(
            au, kAudioUnitProperty_ClassInfo,
            kAudioUnitScope_Global, 0,
            &mutablePlist, UInt32(MemoryLayout<CFPropertyList?>.size)
        )
        if err != noErr {
            logger.warning("Failed to load preset: \(err)")
            return false
        }
        queryTailTime()
        return true
    }

    func selectFactoryPreset(index: Int) -> Bool {
        guard let au = _audioUnit else { return false }
        var preset = AUPreset(presetNumber: Int32(index), presetName: nil)
        let err = AudioUnitSetProperty(
            au, kAudioUnitProperty_PresentPreset,
            kAudioUnitScope_Global, 0,
            &preset, UInt32(MemoryLayout<AUPreset>.size)
        )
        if err != noErr {
            logger.warning("Failed to select factory preset \(index): \(err)")
            return false
        }
        queryTailTime()
        return true
    }

    // MARK: - Private

    private func loadFactoryPresets() {
        guard let au = _audioUnit else { return }
        var presetsRef: CFArray?
        var size = UInt32(MemoryLayout<CFArray?>.size)
        let err = AudioUnitGetProperty(
            au, kAudioUnitProperty_FactoryPresets,
            kAudioUnitScope_Global, 0,
            &presetsRef, &size
        )
        guard err == noErr, let cfArray = presetsRef else {
            factoryPresets = []
            return
        }

        let count = CFArrayGetCount(cfArray)
        var result: [(index: Int, name: String)] = []
        for i in 0..<count {
            guard let ptr = CFArrayGetValueAtIndex(cfArray, i) else { continue }
            let preset = ptr.load(as: AUPreset.self)
            let name: String
            if let cfName = preset.presetName {
                name = cfName.takeUnretainedValue() as String
            } else {
                name = "Preset \(preset.presetNumber)"
            }
            result.append((index: Int(preset.presetNumber), name: name))
        }
        factoryPresets = result
    }

    private func queryTailTime() {
        guard let au = _audioUnit else { return }
        var tailTime: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let err = AudioUnitGetProperty(
            au, kAudioUnitProperty_TailTime,
            kAudioUnitScope_Global, 0,
            &tailTime, &size
        )
        tailTimeSeconds = (err == noErr && tailTime.isFinite) ? tailTime : 0
    }
}

// MARK: - Render Callback (C function)

/// Provides input to the AU by copying from the host's pre-deinterleaved buffers.
/// Called synchronously by AudioUnitRender on the RT thread.
private func auRenderCallback(
    _ inRefCon: UnsafeMutableRawPointer,
    _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
    _ inBusNumber: UInt32,
    _ inNumberFrames: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    guard let ioData else { return noErr }
    let host = Unmanaged<AUEffectHost>.fromOpaque(inRefCon).takeUnretainedValue()

    let outputBufs = UnsafeMutableAudioBufferListPointer(ioData)

    // Copy deinterleaved L/R buffers into the AU's input buffers
    if outputBufs.count >= 1, let dst = outputBufs[0].mData {
        let copyBytes = min(Int(outputBufs[0].mDataByteSize), host._bufferCapacity * MemoryLayout<Float>.size)
        memcpy(dst, host._bufferL, copyBytes)
    }
    if outputBufs.count >= 2, let dst = outputBufs[1].mData {
        let copyBytes = min(Int(outputBufs[1].mDataByteSize), host._bufferCapacity * MemoryLayout<Float>.size)
        memcpy(dst, host._bufferR, copyBytes)
    }

    return noErr
}
