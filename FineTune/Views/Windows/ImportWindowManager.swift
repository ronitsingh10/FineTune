import SwiftUI
import AppKit

@MainActor
class ImportWindowManager: NSObject, NSWindowDelegate {
    static let shared = ImportWindowManager()
    
    private var importWindow: NSWindow?
    
    // Explicitly prevent init from outside
    private override init() {
        super.init()
    }
    
    /// Opens the Import Preset window for creating a new preset.
    /// - Parameters:
    ///   - onImport: Callback when a preset is successfully imported.
    func showImportWindow(onImport: @escaping (CustomEQPreset) -> Void) {
        showWindow(existingPreset: nil, onSave: onImport)
    }
    
    /// Opens the Import Preset window for editing an existing preset.
    /// - Parameters:
    ///   - preset: The preset to edit.
    ///   - onSave: Callback when the preset is saved.
    func showEditWindow(preset: CustomEQPreset, onSave: @escaping (CustomEQPreset) -> Void) {
        showWindow(existingPreset: preset, onSave: onSave)
    }
    
    private func showWindow(existingPreset: CustomEQPreset?, onSave: @escaping (CustomEQPreset) -> Void) {
        // If window already exists, bring to front
        if let window = importWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        // Create binding for the sheet to control window closure
        let isPresentedBinding = Binding<Bool>(
            get: { true },
            set: { if !$0 { self.closeWindow() } }
        )
        
        let contentView = ImportPresetSheet(
            isPresented: isPresentedBinding,
            onPresetImported: { preset in
                onSave(preset)
            },
            existingPreset: existingPreset
        )
        
        // Create Window
        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        
        // Configure Window Style
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.isMovableByWindowBackground = true
        window.title = existingPreset != nil ? "Edit Preset" : "Import Preset"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        
        // Set Frame / Position
        window.setContentSize(NSSize(width: 450, height: 500))
        window.center()
        
        window.isReleasedWhenClosed = false
        window.delegate = self
        
        self.importWindow = window
        
        // Show
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    private func closeWindow() {
        importWindow?.close()
        importWindow = nil
    }
    
    // MARK: - NSWindowDelegate
    func windowWillClose(_ notification: Notification) {
        // Handle user clicking the 'x' button
        importWindow = nil
    }
}
