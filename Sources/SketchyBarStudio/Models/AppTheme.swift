import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case nord = "Nord"
    case dracula = "Dracula"
    case monokai = "Monokai"
    case tokyoNight = "Tokyo Night"
    case catppuccin = "Catppuccin"

    var id: String { rawValue }

    var background: Color {
        Color(hex: palette.background) ?? .clear
    }

    var surface: Color {
        Color(hex: palette.surface) ?? .clear
    }

    var accent: Color {
        Color(hex: palette.accent) ?? .clear
    }

    var muted: Color {
        Color(hex: palette.muted) ?? .clear
    }

    var syntaxString: Color {
        Color(hex: palette.string) ?? .clear
    }

    var syntaxNumber: Color {
        Color(hex: palette.number) ?? .clear
    }

    var syntaxVariable: Color {
        Color(hex: palette.variable) ?? .clear
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
