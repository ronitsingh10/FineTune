// FineTuneTests/DesignTokensTests.swift
// Tests that DesignTokens values are valid and consistent.
// No rendering — just value validation.

import Testing
import SwiftUI
@testable import FineTune

// MARK: - Spacing

@Suite("DesignTokens — Spacing scale")
struct DesignTokensSpacingTests {

    @Test("All spacing values are positive")
    func allPositive() {
        #expect(DesignTokens.Spacing.xxs > 0)
        #expect(DesignTokens.Spacing.xs > 0)
        #expect(DesignTokens.Spacing.sm > 0)
        #expect(DesignTokens.Spacing.md > 0)
        #expect(DesignTokens.Spacing.lg > 0)
        #expect(DesignTokens.Spacing.xl > 0)
        #expect(DesignTokens.Spacing.xxl > 0)
    }

    @Test("Spacing scale is strictly increasing")
    func strictlyIncreasing() {
        let scale: [CGFloat] = [
            DesignTokens.Spacing.xxs,
            DesignTokens.Spacing.xs,
            DesignTokens.Spacing.sm,
            DesignTokens.Spacing.md,
            DesignTokens.Spacing.lg,
            DesignTokens.Spacing.xl,
            DesignTokens.Spacing.xxl,
        ]
        for i in 1..<scale.count {
            #expect(scale[i] > scale[i - 1],
                    "Spacing[\(i)] (\(scale[i])) should be > spacing[\(i-1)] (\(scale[i-1]))")
        }
    }

    @Test("Spacing values are reasonable (2-24pt range)")
    func reasonableRange() {
        #expect(DesignTokens.Spacing.xxs == 2)
        #expect(DesignTokens.Spacing.xs == 4)
        #expect(DesignTokens.Spacing.sm == 8)
        #expect(DesignTokens.Spacing.md == 12)
        #expect(DesignTokens.Spacing.lg == 16)
        #expect(DesignTokens.Spacing.xl == 20)
        #expect(DesignTokens.Spacing.xxl == 24)
    }
}

// MARK: - Dimensions

@Suite("DesignTokens — Dimensions")
struct DesignTokensDimensionTests {

    @Test("Popup width is positive and reasonable")
    func popupWidth() {
        #expect(DesignTokens.Dimensions.popupWidth > 300)
        #expect(DesignTokens.Dimensions.popupWidth < 1000)
    }

    @Test("contentWidth is popupWidth minus double padding")
    func contentWidthFormula() {
        let expected = DesignTokens.Dimensions.popupWidth - (DesignTokens.Dimensions.contentPadding * 2)
        #expect(DesignTokens.Dimensions.contentWidth == expected)
    }

    @Test("Corner radii are positive")
    func cornerRadiiPositive() {
        #expect(DesignTokens.Dimensions.cornerRadius > 0)
        #expect(DesignTokens.Dimensions.rowRadius > 0)
        #expect(DesignTokens.Dimensions.buttonRadius > 0)
    }

    @Test("Slider dimensions are positive")
    func sliderDimensionsPositive() {
        #expect(DesignTokens.Dimensions.sliderTrackHeight > 0)
        #expect(DesignTokens.Dimensions.sliderThumbWidth > 0)
        #expect(DesignTokens.Dimensions.sliderThumbHeight > 0)
        #expect(DesignTokens.Dimensions.sliderThumbSize > 0)
    }

    @Test("Icon sizes are positive")
    func iconSizes() {
        #expect(DesignTokens.Dimensions.iconSize > 0)
        #expect(DesignTokens.Dimensions.iconSizeSmall > 0)
        #expect(DesignTokens.Dimensions.iconSizeSmall < DesignTokens.Dimensions.iconSize)
    }

    @Test("VU meter has 8 bars")
    func vuMeterBarCount() {
        #expect(DesignTokens.Dimensions.vuMeterBarCount == 8)
    }

    @Test("Min touch target is at least 16pt (Apple HIG minimum)")
    func minTouchTarget() {
        #expect(DesignTokens.Dimensions.minTouchTarget >= 16)
    }
}

// MARK: - Timing

@Suite("DesignTokens — Timing constants")
struct DesignTokensTimingTests {

    @Test("VU meter update interval is ~30fps")
    func vuMeterInterval() {
        let interval = DesignTokens.Timing.vuMeterUpdateInterval
        #expect(abs(interval - 1.0 / 30.0) < 0.001)
    }

    @Test("VU meter peak hold is positive")
    func vuMeterPeakHold() {
        #expect(DesignTokens.Timing.vuMeterPeakHold > 0)
    }
}
