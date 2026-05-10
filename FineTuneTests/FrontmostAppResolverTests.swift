// FineTuneTests/FrontmostAppResolverTests.swift
import Testing
import Foundation
import AppKit
@testable import FineTune

@Suite("FrontmostAppResolver")
@MainActor
struct FrontmostAppResolverTests {
    private static let ownBundleID = "com.finetuneapp.FineTune"

    @Test("resolveTargetBundleID returns nil when nothing has activated")
    func coldLaunchReturnsNil() {
        let resolver = FrontmostAppResolver(
            ownBundleID: Self.ownBundleID,
            frontmostBundleIDProvider: { Self.ownBundleID }
        )
        #expect(resolver.resolveTargetBundleID() == nil)
    }

    @Test("resolveTargetBundleID returns the frontmost bundle ID when it is not FineTune")
    func returnsFrontmostWhenNotFineTune() {
        let resolver = FrontmostAppResolver(
            ownBundleID: Self.ownBundleID,
            frontmostBundleIDProvider: { "com.apple.Safari" }
        )
        #expect(resolver.resolveTargetBundleID() == "com.apple.Safari")
    }

    @Test("resolveTargetBundleID falls back to last cached non-FineTune ID when FineTune is frontmost")
    func fineTuneFrontmostUsesCachedFallback() {
        let resolver = FrontmostAppResolver(
            ownBundleID: Self.ownBundleID,
            frontmostBundleIDProvider: { Self.ownBundleID }
        )
        resolver.handleActivation(bundleID: "com.apple.Safari")

        #expect(resolver.resolveTargetBundleID() == "com.apple.Safari")
    }

    @Test("activation by FineTune does not overwrite the cached fallback")
    func fineTuneActivationDoesNotPoisonCache() {
        let resolver = FrontmostAppResolver(
            ownBundleID: Self.ownBundleID,
            frontmostBundleIDProvider: { Self.ownBundleID }
        )
        resolver.handleActivation(bundleID: "com.apple.Safari")
        resolver.handleActivation(bundleID: Self.ownBundleID)

        #expect(resolver.resolveTargetBundleID() == "com.apple.Safari")
    }
}
