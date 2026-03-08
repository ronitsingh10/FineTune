// FineTune/Audio/Extensions/AudioDeviceID+Streams.swift
import AudioToolbox
import Foundation

// MARK: - Stream Queries

extension AudioDeviceID {
    private static let outputStreamDirection: UInt32 = 0

    func hasOutputStreams() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard err == noErr else { return false }
        return size > 0
    }

    func hasInputStreams() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard err == noErr else { return false }
        return size > 0
    }

    /// Reads stream object IDs for a given scope.
    private func readStreams(scope: AudioObjectPropertyScope) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var streams = [AudioObjectID](repeating: .unknown, count: count)
        err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &streams)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }
        return streams
    }

    /// Returns the first output stream index in the device's global stream list.
    /// CATapDescription(deviceUID:stream:) expects this global index, not an output-only index.
    func firstOutputStreamIndex() throws -> UInt {
        let globalStreams = try readStreams(scope: kAudioObjectPropertyScopeGlobal)
        for (index, streamID) in globalStreams.enumerated() {
            let direction: UInt32 = try streamID.read(kAudioStreamPropertyDirection, defaultValue: 0)
            if direction == Self.outputStreamDirection {
                return UInt(index)
            }
        }

        // Fallback for devices that do not expose direction on global stream list.
        let outputStreams = try readStreams(scope: kAudioObjectPropertyScopeOutput)
        if !outputStreams.isEmpty {
            return 0
        }

        throw NSError(domain: "AudioDeviceID+Streams", code: -1, userInfo: [NSLocalizedDescriptionKey: "No output stream found"])
    }

    /// Returns preferred stereo channels as zero-based indices.
    /// CoreAudio reports channels as 1-based element numbers.
    func preferredStereoChannelIndices() -> (left: Int, right: Int) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var channels: [UInt32] = [1, 2]
        var size = UInt32(MemoryLayout<UInt32>.size * channels.count)
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &channels)
        guard err == noErr, channels.count >= 2 else { return (0, 1) }

        let left = Swift.max(0, Int(channels[0]) - 1)
        let right = Swift.max(0, Int(channels[1]) - 1)
        return (left, right)
    }
}
