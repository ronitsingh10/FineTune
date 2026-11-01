// FineTune/Views/Components/SectionHeader.swift
import SwiftUI

/// A styled section header for organizing content
/// Renders text in uppercase with letter spacing
struct SectionHeader: View {
    let title: LocalizedStringResource

    var body: some View {
        Text(title)
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
