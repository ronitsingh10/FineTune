import AudioToolbox
import Foundation
import Testing
@testable import FineTune

@Suite("Optional master volume")
@MainActor
struct OptionalMasterVolumeTests {
    @Test("Existing installations default to unchanged media-key behaviour")
    func backwardCompatibleDefaults() throws {
        let old = try JSONDecoder().decode(SettingsManager.Settings.self, from: Data("{}".utf8))
        #expect(!old.appSettings.masterVolumeEnabled)
        #expect(old.masterVolume == 1)
        #expect(!old.masterMuted)
    }

    @Test("Master level and opt-in flag survive JSON encoding and decoding")
    func persistence() throws {
        var settings = SettingsManager.Settings()
        settings.appSettings.masterVolumeEnabled = true
        settings.masterVolume = 0.36
        settings.masterMuted = true
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.appSettings.masterVolumeEnabled)
        #expect(decoded.masterVolume == 0.36)
        #expect(decoded.masterMuted)
    }

    @Test("Master attenuation preserves left-right channel proportions")
    func channelGain() {
        var samples: [Float] = [1, -0.5, 0.25, -1]
        samples.withUnsafeMutableBufferPointer { sampleBuffer in
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(sampleBuffer.count * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(sampleBuffer.baseAddress!)
                )
            )
            withUnsafeMutablePointer(to: &bufferList) { listPointer in
                let buffers = UnsafeMutableAudioBufferListPointer(listPointer)
                let after = MasterVolumeProcessor.process(
                    buffers, targetGain: 0.25, currentGain: 0.25, rampCoefficient: 1
                )
                #expect(after == 0.25)
            }
        }
        #expect(samples == [0.25, -0.125, 0.0625, -0.25])
    }
}
