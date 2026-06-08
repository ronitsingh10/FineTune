// FineTune/Audio/Keys/MediaKeyStatus.swift
import Foundation

/// Transient status for the media-key feature.
/// - `isOffline`: tap disabled twice inside the watchdog window.
/// - `suppressionDegraded`: native HUD fired within 500ms of our swallow.
@Observable
@MainActor
final class MediaKeyStatus {
    var isOffline: Bool = false
    var suppressionDegraded: Bool = false
}
