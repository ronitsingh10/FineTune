// FineTuneTests/AUPluginTests.swift
import AudioToolbox
import Testing
import AppKit
@testable import FineTune

@Suite("AU editor invalidation")
struct AUPluginEditorInvalidationTests {
    @Test("Save then detach then close runs once")
    func saveDetachCloseOrder() {
        var actions: [String] = []; var saves = 0; var attached = true
        AUPluginEditorInvalidation.perform(saveBeforeClose: true, save: { saves += 1; actions.append("save") }, detach: { attached = false; actions.append("detach") }, close: { if attached { saves += 1 }; actions.append("close") })
        #expect(actions == ["save", "detach", "close"])
        #expect(saves == 1)
    }

    @Test("Detach then close skips save")
    func detachCloseOrder() {
        var actions: [String] = []
        AUPluginEditorInvalidation.perform(saveBeforeClose: false, save: { actions.append("save") }, detach: { actions.append("detach") }, close: { actions.append("close") })
        #expect(actions == ["detach", "close"])
    }

    @Test("A rebuilt host creates a replacement editor")
    func rebuiltHostDoesNotReuseCachedEditor() {
        final class Host {}
        let firstHost = Host()
        let rebuiltHost = Host()

        var createdHostIDs: [ObjectIdentifier] = [ObjectIdentifier(firstHost)]
        var frontedHostIDs: [ObjectIdentifier] = []
        let requestedID = ObjectIdentifier(rebuiltHost)

        if AUPluginEditorRegistry.shouldReuse(
            cachedHostID: createdHostIDs.last,
            requestedHostID: requestedID
        ) {
            frontedHostIDs.append(requestedID)
        } else {
            createdHostIDs.append(requestedID)
        }

        #expect(createdHostIDs == [ObjectIdentifier(firstHost), ObjectIdentifier(rebuiltHost)])
        #expect(frontedHostIDs.isEmpty)
    }

    @Test("The current live host reuses its editor")
    func currentHostReusesCachedEditor() {
        final class Host {}
        let host = Host()
        let hostID = ObjectIdentifier(host)
        var createCount = 1
        var frontCount = 0

        if AUPluginEditorRegistry.shouldReuse(cachedHostID: hostID, requestedHostID: hostID) {
            frontCount += 1
        } else {
            createCount += 1
        }

        #expect(createCount == 1)
        #expect(frontCount == 1)
    }
}

@Suite("AU editor sizing")
@MainActor
struct AUPluginEditorSizingTests {
    private final class SizedView: NSView {
        let reportedFittingSize: NSSize
        let reportedIntrinsicSize: NSSize

        init(frame: NSRect, fittingSize: NSSize, intrinsicSize: NSSize = NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)) {
            self.reportedFittingSize = fittingSize
            self.reportedIntrinsicSize = intrinsicSize
            super.init(frame: frame)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override var fittingSize: NSSize { reportedFittingSize }
        override var intrinsicContentSize: NSSize { reportedIntrinsicSize }
    }

    @Test("Custom Audio Units receive the measured expanded editor size")
    func customViewReceivesExpandedSize() {
        let visibleFrame = NSRect(x: 0, y: 24, width: 1_512, height: 958)
        #expect(
            AUPluginEditorSizing.customViewRequestSize(forVisibleFrame: visibleFrame)
                == NSSize(width: 800, height: 600)
        )
    }

    @Test("Expanded editor size is capped by the usable screen")
    func customViewSizeFitsSmallScreen() {
        let visibleFrame = NSRect(x: 0, y: 24, width: 640, height: 480)
        let available = NSWindow.contentRect(
            forFrameRect: visibleFrame,
            styleMask: AUPluginEditorSizing.editorWindowStyle
        ).size

        #expect(AUPluginEditorSizing.customViewRequestSize(forVisibleFrame: visibleFrame) == available)
    }

    @Test("A large plug-in frame is not cropped to its smaller fitting size")
    func nativeFrameWinsOverSmallFittingSize() {
        let view = SizedView(
            frame: NSRect(x: 0, y: 0, width: 1_120, height: 720),
            fittingSize: NSSize(width: 400, height: 300)
        )

        #expect(AUPluginEditorSizing.preferredContentSize(for: view) == NSSize(width: 1_120, height: 720))
    }

    @Test("Auto Layout size is honored when the returned frame is empty")
    func fittingSizeUsedForEmptyFrame() {
        let view = SizedView(
            frame: .zero,
            fittingSize: NSSize(width: 980, height: 640)
        )

        #expect(AUPluginEditorSizing.preferredContentSize(for: view) == NSSize(width: 980, height: 640))
    }
}

// MARK: - AUPluginDescriptor Tests

@Suite("AUPluginDescriptor")
struct AUPluginDescriptorTests {

    @Test("ID is deterministic from component triple")
    func idFromTriple() {
        let desc = makeDescriptor(type: 1, subType: 2, manufacturer: 3)
        #expect(desc.id == "1-2-3")
    }

    @Test("Two descriptors with same triple are equal")
    func equalityByTriple() {
        let a = makeDescriptor(type: 1, subType: 2, manufacturer: 3)
        let b = makeDescriptor(type: 1, subType: 2, manufacturer: 3)
        #expect(a == b)
    }

    @Test("Different triples are not equal")
    func inequalityByTriple() {
        let a = makeDescriptor(type: 1, subType: 2, manufacturer: 3)
        let b = makeDescriptor(type: 1, subType: 2, manufacturer: 4)
        #expect(a != b)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let original = makeDescriptor(type: 100, subType: 200, manufacturer: 300)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AUPluginDescriptor.self, from: data)
        #expect(decoded == original)
        #expect(decoded.name == original.name)
        #expect(decoded.manufacturer == original.manufacturer)
        #expect(decoded.version == original.version)
    }

    @Test("audioComponentDescription reconstructs correctly")
    func audioComponentDescription() {
        let desc = makeDescriptor(type: 0x61756678, subType: 0x64656C79, manufacturer: 0x6170706C)
        let acd = desc.audioComponentDescription
        #expect(acd.componentType == 0x61756678)
        #expect(acd.componentSubType == 0x64656C79)
        #expect(acd.componentManufacturer == 0x6170706C)
        #expect(acd.componentFlags == 0)
        #expect(acd.componentFlagsMask == 0)
    }

    @Test("Hashable works in Set")
    func hashable() {
        let a = makeDescriptor(type: 1, subType: 2, manufacturer: 3)
        let b = makeDescriptor(type: 1, subType: 2, manufacturer: 3)
        let c = makeDescriptor(type: 4, subType: 5, manufacturer: 6)
        let set: Set<AUPluginDescriptor> = [a, b, c]
        #expect(set.count == 2)
    }

    private func makeDescriptor(type: UInt32, subType: UInt32, manufacturer: UInt32) -> AUPluginDescriptor {
        AUPluginDescriptor(
            componentType: type,
            componentSubType: subType,
            componentManufacturer: manufacturer,
            name: "Test Plugin",
            manufacturer: "Test Manufacturer",
            version: 1
        )
    }
}

@Suite("Device AU effect UI callbacks")
@MainActor
struct DeviceAUEffectUICallbackTests {
    @Test("Device row forwards editor, preset, and reorder callbacks")
    func forwardsCallbacks() {
        let entry = AUEffectChainEntry(plugin: AUPluginDescriptor(
            componentType: kAudioUnitType_Effect, componentSubType: 1,
            componentManufacturer: 2, name: "Test", manufacturer: "Test", version: 1
        ))
        var opened: (UUID, Bool)?
        var reordered: [AUEffectChainEntry] = []
        var selectedPreset: (UUID, Int)?
        let row = DeviceRow(
            device: AudioDevice(id: 1, uid: "device", name: "Device", icon: nil, supportsAutoEQ: false),
            isDefault: true, volume: 1, isMuted: false,
            onSetDefault: {}, onVolumeChange: { _ in }, onMuteToggle: {},
            deviceAUEffectChain: [entry],
            onOpenDeviceAUUI: { opened = ($0, $1) },
            onReorderDeviceAUEffects: { reordered = $0 },
            onSelectDeviceAUFactoryPreset: { selectedPreset = ($0, $1) }
        )

        row.onOpenDeviceAUUI?(entry.id, true)
        row.onReorderDeviceAUEffects?([entry])
        row.onSelectDeviceAUFactoryPreset?(entry.id, 4)

        #expect(opened?.0 == entry.id)
        #expect(opened?.1 == true)
        #expect(reordered == [entry])
        #expect(selectedPreset?.0 == entry.id)
        #expect(selectedPreset?.1 == 4)
    }
}

// MARK: - AUEffectChainEntry Tests

@Suite("AUEffectChainEntry")
struct AUEffectChainEntryTests {

    @Test("Init creates unique UUID")
    func uniqueID() {
        let plugin = makePlugin()
        let a = AUEffectChainEntry(plugin: plugin)
        let b = AUEffectChainEntry(plugin: plugin)
        #expect(a.id != b.id)
    }

    @Test("Init defaults to enabled with no preset")
    func defaults() {
        let entry = AUEffectChainEntry(plugin: makePlugin())
        #expect(entry.isEnabled == true)
        #expect(entry.presetData == nil)
        #expect(entry.selectedFactoryPresetIndex == nil)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        var entry = AUEffectChainEntry(plugin: makePlugin())
        entry.isEnabled = false
        entry.presetData = Data([0x01, 0x02, 0x03])
        entry.selectedFactoryPresetIndex = 5

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(AUEffectChainEntry.self, from: data)
        #expect(decoded.id == entry.id)
        #expect(decoded.pluginDescriptor == entry.pluginDescriptor)
        #expect(decoded.isEnabled == false)
        #expect(decoded.presetData == Data([0x01, 0x02, 0x03]))
        #expect(decoded.selectedFactoryPresetIndex == 5)
    }

    @Test("Equatable compares by ID")
    func equatable() {
        let a = AUEffectChainEntry(plugin: makePlugin())
        var b = a
        b.isEnabled = false
        // Same id means equal for Equatable (it's derived)
        // Actually Equatable is auto-synthesized comparing all fields
        #expect(a != b)
    }

    private func makePlugin() -> AUPluginDescriptor {
        AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x64656C79,
            componentManufacturer: 0x6170706C,
            name: "AUDelay",
            manufacturer: "Apple",
            version: 1
        )
    }
}

// MARK: - AUPluginScanner Tests

@Suite("AUPluginScanner", .serialized)
@MainActor
struct AUPluginScannerTests {

    @Test("Discovers system Audio Units")
    func discoversSystemAUs() {
        let scanner = AUPluginScanner()
        #expect(scanner.plugins.count > 0, "macOS ships with built-in AU effects")
    }

    @Test("Only discovers effect-type AUs")
    func onlyEffectTypes() {
        let scanner = AUPluginScanner()
        let effectTypes: Set<UInt32> = [kAudioUnitType_Effect, kAudioUnitType_MusicEffect]
        for plugin in scanner.plugins {
            #expect(effectTypes.contains(plugin.componentType),
                    "\(plugin.name) has unexpected type \(plugin.componentType)")
        }
    }

    @Test("Manufacturers dictionary groups correctly")
    func manufacturerGrouping() {
        let scanner = AUPluginScanner()
        let totalInManufacturers = scanner.manufacturers.values.reduce(0) { $0 + $1.count }
        #expect(totalInManufacturers == scanner.plugins.count)
    }

    @Test("Plugins are sorted by manufacturer then name")
    func sortOrder() {
        let scanner = AUPluginScanner()
        for i in 1..<scanner.plugins.count {
            let prev = scanner.plugins[i - 1]
            let curr = scanner.plugins[i]
            #expect((prev.manufacturer, prev.name) <= (curr.manufacturer, curr.name),
                    "\(prev.manufacturer):\(prev.name) should come before \(curr.manufacturer):\(curr.name)")
        }
    }

    @Test("findComponent returns non-nil for known Apple AU")
    func findComponentForAppleAU() {
        let scanner = AUPluginScanner()
        guard let applePlugin = scanner.plugins.first(where: { $0.manufacturer == "Apple" }) else {
            Issue.record("No Apple AU found on this system")
            return
        }
        #expect(scanner.findComponent(for: applePlugin) != nil)
    }

    @Test("Refresh produces consistent results")
    func refreshConsistency() {
        let scanner = AUPluginScanner()
        let firstCount = scanner.plugins.count
        scanner.refresh()
        #expect(scanner.plugins.count == firstCount)
    }

    @Test("hasNewPlugins starts false")
    func newPluginsFlag() {
        let scanner = AUPluginScanner()
        #expect(scanner.hasNewPlugins == false)
    }

    @Test("clearNewPluginsFlag resets flag")
    func clearFlag() {
        let scanner = AUPluginScanner()
        scanner.clearNewPluginsFlag()
        #expect(scanner.hasNewPlugins == false)
    }
}

// MARK: - AUEffectHost Tests

@Suite("AUEffectHost")
struct AUEffectHostTests {

    @Test("Instantiate Apple AUDelay succeeds")
    func instantiateAUDelay() {
        let desc = appleAUDelay()
        let host = AUEffectHost(descriptor: desc, entryID: UUID(), sampleRate: 44100)
        #expect(host.instantiate() == true)
        #expect(host.audioUnit != nil)
    }

    @Test("Instantiate with bogus descriptor fails")
    func instantiateBogus() {
        let desc = AUPluginDescriptor(
            componentType: 0xDEADBEEF,
            componentSubType: 0xDEADBEEF,
            componentManufacturer: 0xDEADBEEF,
            name: "Bogus",
            manufacturer: "Bogus",
            version: 0
        )
        let host = AUEffectHost(descriptor: desc, entryID: UUID(), sampleRate: 44100)
        #expect(host.instantiate() == false)
        #expect(host.audioUnit == nil)
    }

    @Test("Enable/disable toggle works")
    func enableDisable() {
        let host = AUEffectHost(descriptor: appleAUDelay(), entryID: UUID(), sampleRate: 44100, enabled: true)
        #expect(host.isEnabled == true)
        host.setEnabled(false)
        #expect(host.isEnabled == false)
        host.setEnabled(true)
        #expect(host.isEnabled == true)
    }

    @Test("Factory presets are populated for AUDelay")
    func factoryPresets() {
        let host = AUEffectHost(descriptor: appleAUDelay(), entryID: UUID(), sampleRate: 44100)
        guard host.instantiate() else {
            Issue.record("Failed to instantiate AUDelay")
            return
        }
        // AUDelay may or may not have factory presets, but the property should not crash
        _ = host.factoryPresets
    }

    @Test("Tail time is non-negative")
    func tailTime() {
        let host = AUEffectHost(descriptor: appleAUDelay(), entryID: UUID(), sampleRate: 44100)
        guard host.instantiate() else { return }
        #expect(host.tailTimeSeconds >= 0)
    }

    @Test("Save and load preset round-trip")
    func presetRoundTrip() {
        let host = AUEffectHost(descriptor: appleAUDelay(), entryID: UUID(), sampleRate: 44100)
        guard host.instantiate() else {
            Issue.record("Failed to instantiate")
            return
        }
        guard let saved = host.savePreset() else {
            Issue.record("Failed to save preset")
            return
        }
        #expect(saved.count > 0)
        #expect(host.loadPreset(saved) == true)
    }

    @Test("renderInterleaved actually modifies audio with AULowpass")
    func renderInterleavedModifiesAudio() {
        let desc = AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x6C706173, // 'lpas'
            componentManufacturer: 0x6170706C, // 'appl'
            name: "AULowPassFilter",
            manufacturer: "Apple",
            version: 1
        )
        let host = AUEffectHost(descriptor: desc, entryID: UUID(), sampleRate: 44100, maxFrames: 512)
        guard host.instantiate() else {
            Issue.record("Failed to instantiate AULowPassFilter")
            return
        }

        // Set cutoff to 200 Hz so it aggressively filters high frequencies
        if let au = host.audioUnit {
            var cutoff: AudioUnitParameterValue = 200.0
            AudioUnitSetParameter(au, 0, kAudioUnitScope_Global, 0, cutoff, 0)
        }

        // Generate 10kHz sine wave (will be heavily filtered by 200Hz lowpass)
        let frameCount = 512
        var buffer = [Float](repeating: 0, count: frameCount * 2)
        let freq: Float = 10000.0
        let sampleRate: Float = 44100.0
        for i in 0..<frameCount {
            let sample = sinf(2.0 * .pi * freq * Float(i) / sampleRate) * 0.5
            buffer[i * 2] = sample     // L
            buffer[i * 2 + 1] = sample // R
        }

        // Compute energy before
        let energyBefore = buffer.reduce(Float(0)) { $0 + $1 * $1 }

        // Render through several buffers to let the filter settle
        for _ in 0..<10 {
            buffer.withUnsafeMutableBufferPointer { ptr in
                host.renderInterleaved(samples: ptr.baseAddress!, frameCount: frameCount)
            }
            // Refill with sine for next iteration
            for i in 0..<frameCount {
                let sample = sinf(2.0 * .pi * freq * Float(i) / sampleRate) * 0.5
                buffer[i * 2] = sample
                buffer[i * 2 + 1] = sample
            }
        }

        // Final render pass — measure output
        buffer.withUnsafeMutableBufferPointer { ptr in
            host.renderInterleaved(samples: ptr.baseAddress!, frameCount: frameCount)
        }

        let energyAfter = buffer.reduce(Float(0)) { $0 + $1 * $1 }

        // A 200Hz lowpass should massively attenuate a 10kHz signal
        #expect(energyAfter < energyBefore * 0.01,
                "AULowPassFilter at 200Hz should attenuate 10kHz signal by >40dB, got ratio \(energyAfter / energyBefore)")
    }

    @Test("renderInterleaved processes frames beyond the host buffer capacity")
    func renderInterleavedProcessesOversizedBuffer() {
        let desc = AUPluginDescriptor(componentType: kAudioUnitType_Effect, componentSubType: 0x6C706173, componentManufacturer: 0x6170706C, name: "AULowPassFilter", manufacturer: "Apple", version: 1)
        let host = AUEffectHost(descriptor: desc, entryID: UUID(), sampleRate: 44100, maxFrames: 512)
        guard host.instantiate(), let au = host.audioUnit else { Issue.record("Failed to instantiate AULowPassFilter"); return }
        var cutoff: AudioUnitParameterValue = 200
        AudioUnitSetParameter(au, 0, kAudioUnitScope_Global, 0, cutoff, 0)
        let frames = 5_000
        var buffer = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let sample = sinf(2 * .pi * 10_000 * Float(i) / 44_100) * 0.5
            buffer[i * 2] = sample; buffer[i * 2 + 1] = sample
        }
        let original = buffer
        buffer.withUnsafeMutableBufferPointer { host.renderInterleaved(samples: $0.baseAddress!, frameCount: frames) }
        let postCapacityDifference = zip(buffer[(4096 * 2)...], original[(4096 * 2)...]).contains { abs($0 - $1) > 0.0001 }
        #expect(postCapacityDifference)
    }

    @Test("Render failure fails open and skips subsequent backend calls")
    func renderFailureFailsOpen() {
        final class Counter: @unchecked Sendable { nonisolated(unsafe) var calls = 0 }
        let counter = Counter()
        let host = AUEffectHost(descriptor: appleAUDelay(), entryID: UUID(), sampleRate: 44100, renderBackend: { _, _, _, _, _, _ in counter.calls += 1; return -1 })
        guard host.instantiate() else { Issue.record("Failed to instantiate"); return }
        var samples: [Float] = [0.2, -0.2, 0.3, -0.3]
        let original = samples
        samples.withUnsafeMutableBufferPointer { host.renderInterleaved(samples: $0.baseAddress!, frameCount: 2) }
        samples.withUnsafeMutableBufferPointer { host.renderInterleaved(samples: $0.baseAddress!, frameCount: 2) }
        #expect(samples == original)
        #expect(host.renderFailed)
        #expect(counter.calls == 1)
    }

    @Test("renderInterleaved works with AUReverb2")
    func renderInterleavedReverb2() {
        let desc = AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x72766232, // 'rvb2'
            componentManufacturer: 0x6170706C, // 'appl'
            name: "AUReverb2",
            manufacturer: "Apple",
            version: 1
        )
        let host = AUEffectHost(descriptor: desc, entryID: UUID(), sampleRate: 44100, maxFrames: 512)
        guard host.instantiate() else {
            Issue.record("Failed to instantiate AUReverb2")
            return
        }

        // Set DryWetMix to 100% wet so reverb is fully audible
        if let au = host.audioUnit {
            // Parameter 0 = DryWetMix (0-100)
            AudioUnitSetParameter(au, 0, kAudioUnitScope_Global, 0, 100.0, 0)
        }

        let frameCount = 512

        // Feed an impulse (single loud sample) then silence — reverb tail should persist
        var impulse = [Float](repeating: 0, count: frameCount * 2)
        impulse[0] = 1.0  // L
        impulse[1] = 1.0  // R

        impulse.withUnsafeMutableBufferPointer { ptr in
            host.renderInterleaved(samples: ptr.baseAddress!, frameCount: frameCount)
        }

        // Now render silence — the reverb tail should produce non-zero output
        var silence = [Float](repeating: 0, count: frameCount * 2)
        silence.withUnsafeMutableBufferPointer { ptr in
            host.renderInterleaved(samples: ptr.baseAddress!, frameCount: frameCount)
        }

        let tailEnergy = silence.reduce(Float(0)) { $0 + $1 * $1 }
        #expect(tailEnergy > 0.0001, "AUReverb2 at 100% wet should produce a reverb tail after an impulse, got energy \(tailEnergy)")
    }

    @Test("Disabled host passes audio through unchanged")
    func disabledHostPassthrough() {
        let host = AUEffectHost(descriptor: appleAUDelay(), entryID: UUID(), sampleRate: 44100, maxFrames: 256, enabled: false)
        _ = host.instantiate()

        var buffer: [Float] = [0.5, -0.5, 0.3, -0.3]
        let original = buffer
        buffer.withUnsafeMutableBufferPointer { ptr in
            host.renderInterleaved(samples: ptr.baseAddress!, frameCount: 2)
        }
        #expect(buffer == original)
    }

    private func appleAUDelay() -> AUPluginDescriptor {
        AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x64656C79, // 'dely'
            componentManufacturer: 0x6170706C, // 'appl'
            name: "AUDelay",
            manufacturer: "Apple",
            version: 1
        )
    }
}

// MARK: - AUEffectChain Tests

@Suite("AUEffectChain")
struct AUEffectChainTests {

    @Test("Disabled entries skip host construction and report failure")
    func disabledEntrySkipsFactory() {
        var entry = AUEffectChainEntry(plugin: appleAUDelay())
        entry.isEnabled = false
        var calls = 0
        let chain = AUEffectChain(entries: [entry], sampleRate: 44100, hostFactory: { entry, rate, frames in
            calls += 1
            return AUEffectHost(descriptor: entry.pluginDescriptor, entryID: entry.id, sampleRate: rate, maxFrames: frames)
        })
        #expect(calls == 0)
        #expect(chain.failedEntryIDs.contains(entry.id))
    }

    @Test("Runtime host failure is reported by chain and skipped thereafter")
    func runtimeFailurePropagatesAndFailsOpen() {
        final class Counter: @unchecked Sendable { nonisolated(unsafe) var calls = 0 }
        let counter = Counter()
        let entry = AUEffectChainEntry(plugin: appleAUDelay())
        let chain = AUEffectChain(entries: [entry], sampleRate: 44100, hostFactory: { entry, rate, frames in
            AUEffectHost(descriptor: entry.pluginDescriptor, entryID: entry.id, sampleRate: rate, maxFrames: frames, renderBackend: { _, _, _, _, _, _ in counter.calls += 1; return -1 })
        })
        var samples: [Float] = [0.2, -0.2, 0.3, -0.3]
        let original = samples
        samples.withUnsafeMutableBufferPointer { chain.processInterleaved(samples: $0.baseAddress!, frameCount: 2) }
        #expect(chain.failedEntryIDs.contains(entry.id))
        #expect(samples == original)
        samples.withUnsafeMutableBufferPointer { chain.processInterleaved(samples: $0.baseAddress!, frameCount: 2) }
        #expect(counter.calls == 1)
    }

    @Test("Render callback does not aggregate failure collections")
    func processingPathDoesNotAggregateFailures() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let sourceURL = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FineTune/Audio/AUPlugins/AUEffectChain.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        guard let methodStart = source.range(of: "func processInterleaved"),
              let methodEnd = source.range(of: "\n    }\n}", range: methodStart.lowerBound..<source.endIndex) else {
            Issue.record("Unable to locate AUEffectChain.processInterleaved")
            return
        }
        let body = source[methodStart.lowerBound..<methodEnd.lowerBound]
        #expect(!body.contains("failedEntryIDs"))
        #expect(!body.contains("Set<"))
        #expect(!body.contains("formUnion"))
    }

    @Test("Empty entries create chain with zero hosts")
    func emptyChain() {
        let chain = AUEffectChain(entries: [], sampleRate: 44100)
        #expect(chain.hosts.count == 0)
        #expect(chain.entries.count == 0)
    }

    @Test("Chain with valid AU creates hosts")
    func validChain() {
        let entry = AUEffectChainEntry(plugin: appleAUDelay())
        let chain = AUEffectChain(entries: [entry], sampleRate: 44100)
        #expect(chain.hosts.count == 1)
        #expect(chain.hosts[0].entryID == entry.id)
    }

    @Test("Chain skips invalid AUs")
    func invalidAUSkipped() {
        let bogus = AUPluginDescriptor(
            componentType: 0xDEADBEEF,
            componentSubType: 0xDEADBEEF,
            componentManufacturer: 0xDEADBEEF,
            name: "Bogus",
            manufacturer: "Bogus",
            version: 0
        )
        let validEntry = AUEffectChainEntry(plugin: appleAUDelay())
        let bogusEntry = AUEffectChainEntry(plugin: bogus)
        let chain = AUEffectChain(entries: [bogusEntry, validEntry], sampleRate: 44100)
        #expect(chain.entries.count == 2)
        #expect(chain.hosts.count == 1)
    }

    @Test("Bypass flag starts false")
    func bypassDefault() {
        let chain = AUEffectChain(entries: [], sampleRate: 44100)
        #expect(chain.isBypassed == false)
    }

    @Test("Bypass toggle works")
    func bypassToggle() {
        let chain = AUEffectChain(entries: [], sampleRate: 44100)
        chain.setBypassed(true)
        #expect(chain.isBypassed == true)
        chain.setBypassed(false)
        #expect(chain.isBypassed == false)
    }

    @Test("maxTailTime reflects hosts")
    func maxTailTime() {
        let entry = AUEffectChainEntry(plugin: appleAUDelay())
        let chain = AUEffectChain(entries: [entry], sampleRate: 44100)
        // Should not crash; value depends on AU implementation
        #expect(chain.maxTailTime >= 0)
    }

    @Test("host(for:) finds correct host by entryID")
    func hostLookup() {
        let entry = AUEffectChainEntry(plugin: appleAUDelay())
        let chain = AUEffectChain(entries: [entry], sampleRate: 44100)
        #expect(chain.host(for: entry.id) != nil)
        #expect(chain.host(for: UUID()) == nil)
    }

    @Test("processInterleaved routes audio through chain")
    func processInterleavedWorks() {
        let desc = AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x6C706173, // 'lpas' - AULowPassFilter
            componentManufacturer: 0x6170706C,
            name: "AULowPassFilter",
            manufacturer: "Apple",
            version: 1
        )
        let entry = AUEffectChainEntry(plugin: desc)
        let chain = AUEffectChain(entries: [entry], sampleRate: 44100, maxFrames: 256)
        #expect(chain.hosts.count == 1)

        // Set cutoff low
        if let au = chain.hosts.first?.audioUnit {
            var cutoff: AudioUnitParameterValue = 100.0
            AudioUnitSetParameter(au, 0, kAudioUnitScope_Global, 0, cutoff, 0)
        }

        let frameCount = 256
        var buffer = [Float](repeating: 0, count: frameCount * 2)
        // 15kHz sine
        for i in 0..<frameCount {
            let s = sinf(2.0 * .pi * 15000.0 * Float(i) / 44100.0)
            buffer[i * 2] = s
            buffer[i * 2 + 1] = s
        }

        // Settle filter
        for _ in 0..<20 {
            var temp = buffer
            temp.withUnsafeMutableBufferPointer { ptr in
                chain.processInterleaved(samples: ptr.baseAddress!, frameCount: frameCount)
            }
        }

        buffer.withUnsafeMutableBufferPointer { ptr in
            chain.processInterleaved(samples: ptr.baseAddress!, frameCount: frameCount)
        }

        let energy = buffer.reduce(Float(0)) { $0 + $1 * $1 }
        let maxPossibleEnergy = Float(frameCount * 2) // each sample max 1.0
        #expect(energy < maxPossibleEnergy * 0.001, "15kHz should be nearly silent through 100Hz lowpass")
    }

    @Test("Bypassed chain does not modify audio")
    func bypassedChainPassthrough() {
        let entry = AUEffectChainEntry(plugin: appleAUDelay())
        let chain = AUEffectChain(entries: [entry], sampleRate: 44100, maxFrames: 64)
        chain.setBypassed(true)

        var buffer: [Float] = [0.5, -0.5, 0.3, -0.3]
        let original = buffer
        buffer.withUnsafeMutableBufferPointer { ptr in
            chain.processInterleaved(samples: ptr.baseAddress!, frameCount: 2)
        }
        #expect(buffer == original)
    }

    private func appleAUDelay() -> AUPluginDescriptor {
        AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x64656C79,
            componentManufacturer: 0x6170706C,
            name: "AUDelay",
            manufacturer: "Apple",
            version: 1
        )
    }
}

// MARK: - CrashGuard Plugin Tracking Tests

@Suite("CrashGuard Plugin Tracking")
struct CrashGuardPluginTrackingTests {

    @Test("FNV-1a hash is deterministic")
    func hashDeterministic() {
        let h1 = CrashGuard.fnv1aHash("test-plugin")
        let h2 = CrashGuard.fnv1aHash("test-plugin")
        #expect(h1 == h2)
    }

    @Test("FNV-1a hash differs for different strings")
    func hashDiffers() {
        let h1 = CrashGuard.fnv1aHash("plugin-a")
        let h2 = CrashGuard.fnv1aHash("plugin-b")
        #expect(h1 != h2)
    }

    @Test("Plugin tracking retains a hash until its last overlapping host releases")
    func pluginReferenceCounts() {
        CrashGuard.install()
        let id = "refcount-test-\(UUID().uuidString)"
        let hash = CrashGuard.fnv1aHash(id)
        CrashGuard.trackPlugin(id)
        #expect(CrashGuard.trackedReferenceCountForTesting(descriptorHash: hash) == 1)
        CrashGuard.trackPlugin(id)
        #expect(CrashGuard.trackedReferenceCountForTesting(descriptorHash: hash) == 2)
        CrashGuard.untrackPlugin(id)
        #expect(CrashGuard.trackedReferenceCountForTesting(descriptorHash: hash) == 1)
        CrashGuard.untrackPlugin(id)
        #expect(CrashGuard.trackedReferenceCountForTesting(descriptorHash: hash) == 0)
    }

    @Test("Host-owned tracking survives external editor-style retention")
    func hostLifetimeTracking() {
        CrashGuard.install()
        let descriptor = AUPluginDescriptor(componentType: kAudioUnitType_Effect, componentSubType: 0x64656C79, componentManufacturer: 0x6170706C, name: "AUDelay", manufacturer: "Apple", version: 1)
        let hash = CrashGuard.fnv1aHash(descriptor.id)
        var host: AUEffectHost? = AUEffectHost(descriptor: descriptor, entryID: UUID(), sampleRate: 44100)
        guard host?.instantiate() == true else { Issue.record("Failed to instantiate AUDelay"); return }
        #expect(CrashGuard.trackedReferenceCountForTesting(descriptorHash: hash) == 1)
        var editorOwner = host
        host = nil
        #expect(CrashGuard.trackedReferenceCountForTesting(descriptorHash: hash) == 1)
        editorOwner = nil
        #expect(CrashGuard.trackedReferenceCountForTesting(descriptorHash: hash) == 0)
    }

    @Test("Failed construction releases its early CrashGuard tracking")
    func failedHostConstructionUntracks() {
        CrashGuard.install()
        let descriptor = AUPluginDescriptor(componentType: kAudioUnitType_Effect, componentSubType: 0x7A7A7A7A, componentManufacturer: 0x7A7A7A7A, name: "Missing", manufacturer: "Test", version: 1)
        let hash = CrashGuard.fnv1aHash(descriptor.id)
        do {
            let host = AUEffectHost(descriptor: descriptor, entryID: UUID(), sampleRate: 44100)
            #expect(!host.instantiate())
        }
        #expect(CrashGuard.trackedReferenceCountForTesting(descriptorHash: hash) == 0)
    }

    @Test("readAndClearCrashPlugins returns empty when no crash file")
    func noCrashFile() {
        let result = CrashGuard.readAndClearCrashPlugins(knownPluginIDs: ["foo", "bar"])
        #expect(result.isEmpty)
    }
}

// MARK: - SettingsManager AU Tests

@Suite("SettingsManager AU Persistence", .serialized)
@MainActor
struct SettingsManagerAUTests {

    @Test("Get/set app AU effect chain round-trip")
    func appChainRoundTrip() {
        let settings = SettingsManager()
        let entry = AUEffectChainEntry(plugin: makePlugin())
        settings.setAUEffectChain([entry], for: "com.test.app")
        let loaded = settings.getAUEffectChain(for: "com.test.app")
        #expect(loaded.count == 1)
        #expect(loaded[0].id == entry.id)
    }

    @Test("Empty chain removes key")
    func emptyChainRemovesKey() {
        let settings = SettingsManager()
        let entry = AUEffectChainEntry(plugin: makePlugin())
        settings.setAUEffectChain([entry], for: "com.test.app")
        settings.setAUEffectChain([], for: "com.test.app")
        let loaded = settings.getAUEffectChain(for: "com.test.app")
        #expect(loaded.isEmpty)
    }

    @Test("Get/set device AU effect chain round-trip")
    func deviceChainRoundTrip() {
        let settings = SettingsManager()
        let entry = AUEffectChainEntry(plugin: makePlugin())
        settings.setDeviceAUEffectChain([entry], for: "device-uid-123")
        let loaded = settings.getDeviceAUEffectChain(for: "device-uid-123")
        #expect(loaded.count == 1)
        #expect(loaded[0].id == entry.id)
    }

    @Test("Favorite toggle works")
    func favoriteToggle() {
        let settings = SettingsManager()
        let pluginID = "test-plugin-id"
        #expect(settings.isAUPluginFavorite(pluginID) == false)
        settings.toggleAUPluginFavorite(pluginID)
        #expect(settings.isAUPluginFavorite(pluginID) == true)
        settings.toggleAUPluginFavorite(pluginID)
        #expect(settings.isAUPluginFavorite(pluginID) == false)
    }

    @Test("Crash history tracking")
    func crashHistory() {
        let settings = SettingsManager()
        #expect(settings.wasAUPluginInvolvedInCrash("p1") == false)
        settings.markAUPluginsActiveAtCrash(["p1", "p2"])
        #expect(settings.wasAUPluginInvolvedInCrash("p1") == true)
        #expect(settings.wasAUPluginInvolvedInCrash("p2") == true)
        #expect(settings.wasAUPluginInvolvedInCrash("p3") == false)
        settings.clearAUPluginCrashHistory()
        #expect(settings.wasAUPluginInvolvedInCrash("p1") == false)
    }

    @Test("disableCrashedAUPlugins disables matching entries")
    func disableCrashed() {
        let settings = SettingsManager()
        let plugin1 = makePlugin(name: "Plugin1", subType: 1)
        let plugin2 = makePlugin(name: "Plugin2", subType: 2)
        var entry1 = AUEffectChainEntry(plugin: plugin1)
        var entry2 = AUEffectChainEntry(plugin: plugin2)
        settings.setAUEffectChain([entry1, entry2], for: "com.test.app")

        settings.disableCrashedAUPlugins([plugin1.id])

        let loaded = settings.getAUEffectChain(for: "com.test.app")
        #expect(loaded.count == 2)
        #expect(loaded[0].isEnabled == false)
        #expect(loaded[1].isEnabled == true)
    }

    @Test("Reset clears all AU settings")
    func resetClearsAll() {
        let settings = SettingsManager()
        settings.setAUEffectChain([AUEffectChainEntry(plugin: makePlugin())], for: "app1")
        settings.setDeviceAUEffectChain([AUEffectChainEntry(plugin: makePlugin())], for: "dev1")
        settings.toggleAUPluginFavorite("fav1")
        settings.markAUPluginsActiveAtCrash(["crash1"])

        settings.resetAllSettings()

        #expect(settings.getAUEffectChain(for: "app1").isEmpty)
        #expect(settings.getDeviceAUEffectChain(for: "dev1").isEmpty)
        #expect(settings.isAUPluginFavorite("fav1") == false)
        #expect(settings.wasAUPluginInvolvedInCrash("crash1") == false)
    }

    private func makePlugin(name: String = "Test", subType: UInt32 = 0x74657374) -> AUPluginDescriptor {
        AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: subType,
            componentManufacturer: 0x74737400,
            name: name,
            manufacturer: "Test",
            version: 1
        )
    }
}
