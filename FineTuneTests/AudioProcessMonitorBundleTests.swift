// FineTuneTests/AudioProcessMonitorBundleTests.swift
//
// Nested helper apps (Electron/Chromium renderers inside Contents/Frameworks) are listed by
// NSWorkspace as running .app bundles. They must not be treated as top-level apps, or their
// audio splits into a separate "Helper" row instead of merging into the parent app.

import Foundation
import Testing
@testable import FineTune

@Suite struct AudioProcessMonitorBundleTests {
    @Test func topLevelAppIsReal() {
        #expect(AudioProcessMonitor.isTopLevelAppBundle(URL(fileURLWithPath: "/Applications/Discord.app")))
    }

    @Test func nestedHelperAppIsNotReal() {
        let url = URL(fileURLWithPath: "/Applications/Discord.app/Contents/Frameworks/Discord Helper (Renderer).app")
        #expect(!AudioProcessMonitor.isTopLevelAppBundle(url))
    }

    @Test func xpcServiceAndNilAreNotReal() {
        #expect(!AudioProcessMonitor.isTopLevelAppBundle(URL(fileURLWithPath: "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.GPU.xpc")))
        #expect(!AudioProcessMonitor.isTopLevelAppBundle(nil))
    }
}
