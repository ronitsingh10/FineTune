// FineTune/Audio/Extensions/AudioObjectID+Properties.swift
import AudioToolbox
import Foundation

// MARK: - AudioObjectID Core Extensions

extension AudioObjectID {
    static let unknown = AudioObjectID(kAudioObjectUnknown)
    static let system = AudioObjectID(kAudioObjectSystemObject)

    var isValid: Bool { self != Self.unknown }
}

// MARK: - Property Reading

extension AudioObjectID {
    func read<T>(
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
        let err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, ptr)
        }
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

        var cfString: CFString = "" as CFString
        err = withUnsafeMutablePointer(to: &cfString) { ptr in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, ptr)
        }
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }
        return cfString as String
    }
}
