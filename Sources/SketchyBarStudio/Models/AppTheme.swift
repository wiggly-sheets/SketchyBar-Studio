import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case nord = "Nord"
    case dracula = "Dracula"
    case monokai = "Monokai"
    case tokyoNight = "Tokyo Night"
    case catppuccin = "Catppuccin"

    var id: String { rawValue }

    var background: Color { Self.resolved[self]?.background ?? .clear }

    var surface: Color { Self.resolved[self]?.surface ?? .clear }

    var accent: Color { Self.resolved[self]?.accent ?? .clear }

    var muted: Color { Self.resolved[self]?.muted ?? .clear }

    var syntaxString: Color { Self.resolved[self]?.string ?? .clear }

    var syntaxNumber: Color { Self.resolved[self]?.number ?? .clear }

    var syntaxVariable: Color { Self.resolved[self]?.variable ?? .clear }

    /// The colors of a theme, parsed once.
    ///
    /// A body pass reads several of them, and the simulation reads them on
    /// every item, so parsing the hex strings again and again would allocate
    /// a new color for every read.
    private struct ResolvedColors {
        let background: Color
        let surface: Color
        let accent: Color
        let muted: Color
        let string: Color
        let number: Color
        let variable: Color
    }

    private static let resolved: [AppTheme: ResolvedColors] = {
        var colors: [AppTheme: ResolvedColors] = [:]
        for theme in AppTheme.allCases {
            let palette = theme.palette
            colors[theme] = ResolvedColors(
                background: Color(hex: palette.background) ?? .clear,
                surface: Color(hex: palette.surface) ?? .clear,
                accent: Color(hex: palette.accent) ?? .clear,
                muted: Self.readableTextColor(palette.muted, on: palette.surface),
                string: Color(hex: palette.string) ?? .clear,
                number: Color(hex: palette.number) ?? .clear,
                variable: Color(hex: palette.variable) ?? .clear
            )
        }
        return colors
    }()

    /// The muted color, lifted until caption text is readable on the
    /// surface of the theme.
    ///
    /// Several palettes use a muted tone that is only decoration; a caption
    /// in it can fall below the WCAG AA contrast. The hue is kept and the
    /// color is mixed toward white or black until it reaches 4.5:1.
    private static func readableTextColor(_ hex: String, on surface: String) -> Color {
        let targetRatio = 4.5
        if BarPalette.contrastRatio(between: hex, and: surface) >= targetRatio {
            return Color(hex: hex) ?? .secondary
        }
        let surfaceColor = Color(hex: surface) ?? .black
        let bytes = hexBytes(surface)
        let backgroundIsDark = (Double(bytes.red) + Double(bytes.green) + Double(bytes.blue)) / 3 < 128
        let target = backgroundIsDark ? "ffffff" : "000000"
        var candidate = hex
        for step in 1...10 {
            candidate = mix(hex, target, amount: Double(step) / 10)
            if BarPalette.contrastRatio(between: candidate, and: surface) >= targetRatio {
                return Color(hex: candidate) ?? surfaceColor
            }
        }
        return backgroundIsDark ? .white : .black
    }

    private static func hexBytes(_ hex: String) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let cleaned = hex.replacingOccurrences(of: "#", with: "")
        guard let integer = UInt64(cleaned, radix: 16) else { return (0, 0, 0) }
        return (UInt8((integer >> 16) & 0xff), UInt8((integer >> 8) & 0xff), UInt8(integer & 0xff))
    }

    private static func mix(_ first: String, _ second: String, amount: Double) -> String {
        let a = hexBytes(first)
        let b = hexBytes(second)
        let mix = { (lhs: UInt8, rhs: UInt8) -> Int in
            Int((Double(lhs) * (1 - amount) + Double(rhs) * amount).rounded())
        }
        return String(format: "#%02x%02x%02x", mix(a.red, b.red), mix(a.green, b.green), mix(a.blue, b.blue))
    }

    private var palette: (background: String, surface: String, accent: String, muted: String, string: String, number: String, variable: String) {
        switch self {
        case .nord:
            return ("#2e3440", "#3b4252", "#88c0d0", "#81a1c1", "#a3be8c", "#b48ead", "#ebcb8b")
        case .dracula:
            return ("#282a36", "#343746", "#bd93f9", "#6272a4", "#f1fa8c", "#ffb86c", "#8be9fd")
        case .monokai:
            return ("#272822", "#3e3d32", "#a6e22e", "#75715e", "#e6db74", "#ae81ff", "#66d9ef")
        case .tokyoNight:
            return ("#1a1b26", "#24283b", "#7aa2f7", "#565f89", "#9ece6a", "#ff9e64", "#7dcfff")
        case .catppuccin:
            return ("#1e1e2e", "#313244", "#cba6f7", "#6c7086", "#a6e3a1", "#fab387", "#89dceb")
        }
    }
}

private extension Color {
    /// A color from a hex string. A value that cannot be read returns nil
    /// instead of a wrong color.
    init?(hex: String) {
        let cleaned = hex.replacingOccurrences(of: "#", with: "")
        guard let integer = UInt64(cleaned, radix: 16) else { return nil }
        self = Color(
            red: Double((integer >> 16) & 0xff) / 255,
            green: Double((integer >> 8) & 0xff) / 255,
            blue: Double(integer & 0xff) / 255
        )
    }
}
