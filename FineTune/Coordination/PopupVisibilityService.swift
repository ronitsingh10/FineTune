// FineTune/Audio/Keys/PopupVisibilityService.swift
import Foundation

/// `true` while the menu-bar popup is visible. Read by the HUD to skip overlay display.
@Observable
@MainActor
final class PopupVisibilityService {
    var isVisible: Bool = false
}
