import AppKit
import AudioToolbox
import Testing
@testable import FineTune

@Suite("Process tap — persistent output guard")
@MainActor
struct ProcessTapOutputGuardTests {
    @Test("Source guard mutes all streams of only the managed processes without an output device")
    func sourceGuardHasNoDeviceDependency() {
        let description = ProcessTapController.outputGuardDescription(processObjectIDs: [41, 42])
        #expect(description.muteBehavior == .muted)
        #expect(description.deviceUID == nil)
        #expect(description.stream == nil)
        #expect(description.isMixdown)
        #expect(!description.isExclusive)
        #expect(description.isPrivate)
        #expect(description.processes == [41, 42])
    }

    @Test("Policy blocking preserves the user's independent mute and gain")
    func policyBlockDoesNotChangeUserSettings() {
        let app = AudioApp(id: 9001, processObjectIDs: [], name: "Offline test", icon: NSImage(), bundleID: nil)
        let controller = ProcessTapController(app: app, targetDeviceUID: "disconnected-output")
        controller.volume = 0.37
        controller.isMuted = true
        controller.outputBlocked = true
        #expect(controller.isMuted)
        #expect(controller.volume == 0.37)
        controller.isMuted = false
        #expect(controller.outputBlocked)
        controller.outputBlocked = false
        #expect(!controller.isMuted)
        #expect(controller.volume == 0.37)
    }

    @Test("Every output buffer is zeroed before primary or secondary role processing")
    func policyBlockSilencesAllBuffers() {
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<AudioBufferList>.size + 2 * MemoryLayout<AudioBuffer>.stride,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        let pointer = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        pointer.pointee.mNumberBuffers = 3
        let buffers = UnsafeMutableAudioBufferListPointer(pointer)
        let left = UnsafeMutablePointer<Float>.allocate(capacity: 16)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: 16)
        defer { left.deallocate(); right.deallocate() }
        left.initialize(repeating: 0.75, count: 16)
        right.initialize(repeating: -0.25, count: 16)
        buffers[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 64, mData: left)
        buffers[1] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 64, mData: right)
        buffers[2] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 64, mData: nil)

        #expect(ProcessTapController.silenceGuardedOutputIfNeeded(outputBlocked: true, outputBufferList: buffers.unsafeMutablePointer))
        #expect((0..<16).allSatisfy { left[$0] == 0 && right[$0] == 0 })
    }

    @Test("Unblocked gate leaves samples untouched for normal DSP")
    func openPolicyGateDoesNotAlterAudio() {
        var samples: [Float] = [0.75, -0.25, 0.5, -0.5]
        samples.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
            #expect(!ProcessTapController.silenceGuardedOutputIfNeeded(outputBlocked: false, outputBufferList: &list))
        }
        #expect(samples == [0.75, -0.25, 0.5, -0.5])
    }
}
