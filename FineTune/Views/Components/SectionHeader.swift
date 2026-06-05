// FineTune/Views/Components/SectionHeader.swift
import SwiftUI

/// A styled section header for organizing content
/// Renders text in uppercase with letter spacing
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(L10n.string(title))
            .sectionHeaderStyle()
    }
}

// MARK: - Previews

#Preview("Section Headers") {
    ComponentPreviewContainer {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            SectionHeader(title: "Output Devices")

            SectionHeader(title: "Apps")

            SectionHeader(title: "Active Applications")
        }
    }
}
