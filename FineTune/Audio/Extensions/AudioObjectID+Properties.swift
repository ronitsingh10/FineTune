// FineTune/Audio/Extensions/AudioObjectID+Properties.swift
//
// Error handling convention for extension methods:
//   throws    → Callers must handle failure; no safe default (readDeviceName, readDeviceUID, readProcessPID)
//   -> T      → Safe default exists; returns it on failure (readTransportType → .unknown, readMuteState → false)
//   -> T?     → Value may legitimately not exist (readProcessBundleID, readDeviceIcon)
import AudioToolbox
import Foundation

// MARK: - AudioObjectID Core Extensions

nonisolated extension AudioObjectID {
    static let unknown = AudioObjectID(kAudioObjectUnknown)
    static let system = AudioObjectID(kAudioObjectSystemObject)

    var isValid: Bool { self != Self.unknown }
}

// MARK: - Property Reading

nonisolated extension AudioObjectID {
    func read<T: BitwiseCopyable>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioScope = .global,
        defaultValue: T
    ) throws -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope.propertyScope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<T>.size)
        var value = defaultValue
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }
        return value
    }

    func readBool(_ selector: AudioObjectPropertySelector, scope: AudioScope = .global) throws -> Bool {
        let value: UInt32 = try read(selector, scope: scope, defaultValue: 0)
        return value != 0
    }

    func readString(_ selector: AudioObjectPropertySelector, scope: AudioScope = .global) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope.propertyScope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }

        // CFString-returning selectors transfer +1 ownership per AudioHardwareBase.h
        // ("The caller is responsible for releasing the returned CFObject"). Reading
        // into an Unmanaged slot keeps that retain explicit; takeRetainedValue consumes it.
        var unmanaged: Unmanaged<CFString>? = nil
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        err = withUnsafeMutablePointer(to: &unmanaged) { ptr in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, UnsafeMutableRawPointer(ptr))
        }
        guard err == noErr, let unmanaged else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }
        return unmanaged.takeRetainedValue() as String
    }

    func readStringWithQualifier(
        _ selector: AudioObjectPropertySelector,
        scope: AudioScope = .output,
        qualifier: UInt32
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope.propertyScope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(self, &address) else { return nil }

        // Get actual data size — some HAL plugins write more than MemoryLayout<CFString>.size,
        // corrupting the stack if we use a stack-allocated buffer.
        var qual = qualifier
        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(
            self, &address,
            UInt32(MemoryLayout<UInt32>.size), &qual,
            &dataSize
        )
        guard err == noErr, dataSize > 0 else { return nil }

        // Heap-allocate to avoid stack buffer overflow from buggy drivers
        let capacity = Swift.max(1, Int(dataSize) / MemoryLayout<CFString>.size)
        let buffer = UnsafeMutablePointer<CFString>.allocate(capacity: capacity)
        defer { buffer.deinitialize(count: 1); buffer.deallocate() }
        buffer.initialize(to: "" as CFString)

        err = AudioObjectGetPropertyData(
            self, &address,
            UInt32(MemoryLayout<UInt32>.size), &qual,
            &dataSize, buffer
        )
        guard err == noErr else { return nil }
        return buffer.pointee as String
    }
}

// MARK: - Array Property Reading

nonisolated extension AudioObjectID {
    func readArray<T: BitwiseCopyable>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioScope = .global,
        defaultValue: T
    ) throws -> [T] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope.propertyScope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }

        let count = Int(size) / MemoryLayout<T>.size
        var items = [T](repeating: defaultValue, count: count)
        err = items.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer.baseAddress!)
        }
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }
        return items
    }
}
