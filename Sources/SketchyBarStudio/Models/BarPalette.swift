import Foundation

/// A named colour palette for the SketchyBar bar. The six roles are the same
/// for every palette, so the theme writer can map a key to a role without
/// knowing the palette.
struct BarPalette: Identifiable, Equatable {
    enum Role: String, CaseIterable {
        case background
        case foreground
        case accent
        case accentSecondary
        case muted
        case border
    }

    let id: String
    let displayName: String
    let family: String
    let isDark: Bool
    let background: String
    let foreground: String
    let accent: String
    let accentSecondary: String
    let muted: String
    let border: String
    /// Accent colours of the palette, in source order, for the swatch strip.
    let swatches: [String]

    /// The role colour as six lowercase hex digits, the form a SketchyBar
    /// value uses after its alpha bytes.
    func hex(for role: Role) -> String {
        switch role {
        case .background: return Self.digits(background)
        case .foreground: return Self.digits(foreground)
        case .accent: return Self.digits(accent)
        case .accentSecondary: return Self.digits(accentSecondary)
        case .muted: return Self.digits(muted)
        case .border: return Self.digits(border)
        }
    }

    private static func digits(_ value: String) -> String {
        value.hasPrefix("#") ? String(value.dropFirst()).lowercased() : value.lowercased()
    }

    /// Every palette below is copied from the official palette file named in
    /// `docs/bar-themes/README.md`. A palette that could not be verified is
    /// not in the list.
    static let all: [BarPalette] = [
        BarPalette(
            id: "nord",
            displayName: "Nord",
            family: "Nord",
            isDark: true,
            background: "#2e3440",
            foreground: "#d8dee9",
            accent: "#88c0d0",
            accentSecondary: "#81a1c1",
            muted: "#4c566a",
            border: "#434c5e",
            swatches: ["#8fbcbb", "#88c0d0", "#81a1c1", "#5e81ac", "#b48ead", "#a3be8c", "#ebcb8b", "#d08770", "#bf616a"]
        ),
        BarPalette(
            id: "catppuccin-mocha",
            displayName: "Catppuccin Mocha",
            family: "Catppuccin",
            isDark: true,
            background: "#1e1e2e",
            foreground: "#cdd6f4",
            accent: "#cba6f7",
            accentSecondary: "#89b4fa",
            muted: "#6c7086",
            border: "#45475a",
            swatches: ["#f38ba8", "#fab387", "#f9e2af", "#a6e3a1", "#74c7ec", "#cba6f7"]
        ),
        BarPalette(
            id: "catppuccin-macchiato",
            displayName: "Catppuccin Macchiato",
            family: "Catppuccin",
            isDark: true,
            background: "#24273a",
            foreground: "#cad3f5",
            accent: "#c6a0f6",
            accentSecondary: "#8aadf4",
            muted: "#6e738d",
            border: "#494d64",
            swatches: ["#ed8796", "#f5a97f", "#eed49f", "#a6da95", "#7dc4e4", "#c6a0f6"]
        ),
        BarPalette(
            id: "catppuccin-frappe",
            displayName: "Catppuccin Frappé",
            family: "Catppuccin",
            isDark: true,
            background: "#303446",
            foreground: "#c6d0f5",
            accent: "#ca9ee6",
            accentSecondary: "#8caaee",
            muted: "#737994",
            border: "#51576d",
            swatches: ["#e78284", "#ef9f76", "#e5c890", "#a6d189", "#85c1dc", "#ca9ee6"]
        ),
        BarPalette(
            id: "catppuccin-latte",
            displayName: "Catppuccin Latte",
            family: "Catppuccin",
            isDark: false,
            background: "#eff1f5",
            foreground: "#4c4f69",
            accent: "#8839ef",
            accentSecondary: "#1e66f5",
            muted: "#9ca0b0",
            border: "#bcc0cc",
            swatches: ["#d20f39", "#fe640b", "#df8e1d", "#40a02b", "#209fb5", "#8839ef"]
        ),
        BarPalette(
            id: "solarized-dark",
            displayName: "Solarized Dark",
            family: "Solarized",
            isDark: true,
            background: "#002b36",
            foreground: "#839496",
            accent: "#268bd2",
            accentSecondary: "#2aa198",
            muted: "#586e75",
            border: "#073642",
            swatches: ["#b58900", "#cb4b16", "#dc322f", "#d33682", "#6c71c4", "#268bd2", "#2aa198", "#859900"]
        ),
        BarPalette(
            id: "solarized-light",
            displayName: "Solarized Light",
            family: "Solarized",
            isDark: false,
            background: "#fdf6e3",
            foreground: "#657b83",
            accent: "#268bd2",
            accentSecondary: "#2aa198",
            muted: "#93a1a1",
            border: "#eee8d5",
            swatches: ["#b58900", "#cb4b16", "#dc322f", "#d33682", "#6c71c4", "#268bd2", "#2aa198", "#859900"]
        ),
        BarPalette(
            id: "one-dark",
            displayName: "One Dark",
            family: "One",
            isDark: true,
            background: "#282c34",
            foreground: "#abb2bf",
            accent: "#61afef",
            accentSecondary: "#c678dd",
            muted: "#5c6370",
            border: "#828997",
            swatches: ["#e06c75", "#d19a66", "#e5c07b", "#98c379", "#56b6c2", "#61afef", "#c678dd"]
        ),
        BarPalette(
            id: "one-light",
            displayName: "One Light",
            family: "One",
            isDark: false,
            background: "#fafafa",
            foreground: "#383a42",
            accent: "#4078f2",
            accentSecondary: "#a626a4",
            muted: "#a0a1a7",
            border: "#696c77",
            swatches: ["#e45649", "#986801", "#c18401", "#50a14f", "#0184bc", "#4078f2", "#a626a4"]
        ),
        BarPalette(
            id: "dracula",
            displayName: "Dracula",
            family: "Dracula",
            isDark: true,
            background: "#282a36",
            foreground: "#f8f8f2",
            accent: "#bd93f9",
            accentSecondary: "#ff79c6",
            muted: "#6272a4",
            border: "#44475a",
            swatches: ["#ff5555", "#ffb86c", "#f1fa8c", "#50fa7b", "#8be9fd", "#bd93f9", "#ff79c6"]
        ),
        BarPalette(
            id: "tokyo-night",
            displayName: "Tokyo Night",
            family: "Tokyo Night",
            isDark: true,
            background: "#1a1b26",
            foreground: "#c0caf5",
            accent: "#7aa2f7",
            accentSecondary: "#bb9af7",
            muted: "#565f89",
            border: "#414868",
            swatches: ["#f7768e", "#ff9e64", "#e0af68", "#9ece6a", "#7dcfff", "#7aa2f7", "#bb9af7"]
        ),
        BarPalette(
            id: "gruvbox-dark",
            displayName: "Gruvbox Dark",
            family: "Gruvbox",
            isDark: true,
            background: "#282828",
            foreground: "#ebdbb2",
            accent: "#83a598",
            accentSecondary: "#d3869b",
            muted: "#928374",
            border: "#3c3836",
            swatches: ["#fb4934", "#fe8019", "#fabd2f", "#b8bb26", "#8ec07c", "#83a598", "#d3869b"]
        ),
        BarPalette(
            id: "gruvbox-light",
            displayName: "Gruvbox Light",
            family: "Gruvbox",
            isDark: false,
            background: "#fbf1c7",
            foreground: "#3c3836",
            accent: "#458588",
            accentSecondary: "#b16286",
            muted: "#928374",
            border: "#d5c4a1",
            swatches: ["#9d0006", "#af3a03", "#b57614", "#79740e", "#427b58", "#076678", "#8f3f71"]
        ),
        BarPalette(
            id: "rose-pine",
            displayName: "Rosé Pine",
            family: "Rosé Pine",
            isDark: true,
            background: "#191724",
            foreground: "#e0def4",
            accent: "#c4a7e7",
            accentSecondary: "#9ccfd8",
            muted: "#6e6a86",
            border: "#26233a",
            swatches: ["#eb6f92", "#f6c177", "#ebbcba", "#31748f", "#9ccfd8", "#c4a7e7"]
        ),
        BarPalette(
            id: "rose-pine-moon",
            displayName: "Rosé Pine Moon",
            family: "Rosé Pine",
            isDark: true,
            background: "#232136",
            foreground: "#e0def4",
            accent: "#c4a7e7",
            accentSecondary: "#9ccfd8",
            muted: "#6e6a86",
            border: "#393552",
            swatches: ["#eb6f92", "#f6c177", "#ea9a97", "#3e8fb0", "#9ccfd8", "#c4a7e7"]
        )
    ]
}
