// FineTune/Audio/Types/AudioScope.swift
import AudioToolbox

/// Represents Core Audio property scopes for type-safe property access.
///
/// Future additions if needed:
/// - `playthrough` (kAudioDevicePropertyScopePlayThrough)
/// - `wildcard` (kAudioObjectPropertyScopeWildcard)
nonisolated enum AudioScope: Sendable {
    case global
    case input
    case output

    var propertyScope: AudioObjectPropertyScope {
        switch self {
        case .global: return kAudioObjectPropertyScopeGlobal
        case .input:  return kAudioObjectPropertyScopeInput
        case .output: return kAudioObjectPropertyScopeOutput
        }
    }
}
