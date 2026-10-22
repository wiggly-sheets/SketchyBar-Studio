import SwiftUI

/// Shows a palette before it is applied. This view only reads the palette; the
/// Apply button in the settings remains the only writer.
struct PalettePreviewView: View {
    let palette: BarPalette?

    var body: some View {
        if let palette {
            VStack(alignment: .leading, spacing: 8) {
                mockBar(palette)
                roleGrid(palette)
                swatchStrip(palette)
                Text("\(palette.family) · \(palette.licence) · \(palette.sourceURL)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("\(palette.family) · \(palette.licence) · \(palette.sourceURL)")
            }
        } else {
            Text("Select a palette to preview it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    private func mockBar(_ palette: BarPalette) -> some View {
        // Below a 3:1 foreground/background ratio the preview uses the app
        // contrast colour, so the palette itself is never changed.
        let foreground = palette.foregroundNeedsContrastFallback
            ? Color.primary
            : Color(hexLike: palette.foreground)

        return HStack(spacing: 8) {
            pill("Workspace", color: Color(hexLike: palette.accent), textColor: foreground)
            pill("CPU", color: Color(hexLike: palette.accentSecondary), textColor: foreground)
            Text("42%")
                .font(.caption2.weight(.medium))
                .foregroundStyle(foreground)

            Spacer(minLength: 0)

            Text("secondary")
                .font(.caption2)
                .foregroundStyle(Color(hexLike: palette.muted))
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(
            Color(hexLike: palette.background),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color(hexLike: palette.border), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bar preview of \(palette.displayName)")
    }

    private func pill(_ title: String, color: Color, textColor: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.caption2)
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(color.opacity(0.18), in: Capsule())
    }

    private func roleGrid(_ palette: BarPalette) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
            alignment: .leading,
            spacing: 4
        ) {
            ForEach(BarPalette.displayRoleOrder, id: \.self) { role in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(hexLike: palette.hex(for: role)))
                        .frame(width: 10, height: 10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(.quaternary, lineWidth: 0.5)
                        )

                    Text(roleTitle(role))
                        .font(.caption2)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Text("#" + palette.hex(for: role))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func swatchStrip(_ palette: BarPalette) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(palette.swatches.enumerated()), id: \.offset) { _, hex in
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(hexLike: hex))
                        .frame(height: 12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(.quaternary, lineWidth: 0.5)
                        )

                    Text(hex)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func roleTitle(_ role: BarPalette.Role) -> String {
        switch role {
        case .background: return "Background"
        case .foreground: return "Foreground"
        case .accent: return "Accent"
        case .accentSecondary: return "Accent 2"
        case .muted: return "Muted"
        case .border: return "Border"
        }
    }
}
