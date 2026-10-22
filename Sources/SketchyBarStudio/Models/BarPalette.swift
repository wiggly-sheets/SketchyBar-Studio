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

    /// The hue names a theme key can carry. The service maps a chromatic name
    /// to the nearest swatch of the palette. Grey, white and black use the
    /// luminance rule instead.
    enum Hue: String, CaseIterable {
        case red
        case orange
        case yellow
        case green
        case cyan
        case teal
        case blue
        case purple
        case magenta
        case pink
        case brown
        case grey
        case gray
        case white
        case black

        var degrees: Double? {
            switch self {
            case .red: return 0
            case .orange, .brown: return 30
            case .yellow: return 60
            case .green: return 120
            case .cyan, .teal: return 180
            case .blue: return 240
            case .purple: return 270
            case .magenta: return 300
            case .pink: return 330
            case .grey, .gray, .white, .black: return nil
            }
        }
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
    /// The hue mapping reads the same list.
    let swatches: [String]
    let sourceURL: String
    let licence: String

    /// The order the role rows use in the palette preview.
    static let displayRoleOrder: [Role] = [
        .background, .foreground, .accent, .accentSecondary, .muted, .border
    ]

    /// The WCAG contrast ratio between the palette foreground and background.
    var foregroundContrastRatio: Double {
        Self.contrastRatio(between: foreground, and: background)
    }

    /// True when the palette own text is too close to its own bar. The preview
    /// then uses the app contrast colour instead of changing the palette.
    var foregroundNeedsContrastFallback: Bool {
        foregroundContrastRatio < 3.0
    }

    /// WCAG 2.1 contrast ratio. An unreadable value returns 0, so a broken
    /// palette never claims to be legible.
    static func contrastRatio(between first: String, and second: String) -> Double {
        guard let firstLuminance = relativeLuminance(first),
              let secondLuminance = relativeLuminance(second) else {
            return 0
        }
        let lighter = max(firstLuminance, secondLuminance)
        let darker = min(firstLuminance, secondLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func relativeLuminance(_ value: String) -> Double? {
        let digits = digits(value)
        guard digits.count == 6, let integer = UInt32(digits, radix: 16) else { return nil }

        func channel(_ byte: UInt32) -> Double {
            let component = Double(byte) / 255
            return component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * channel((integer >> 16) & 0xff)
            + 0.7152 * channel((integer >> 8) & 0xff)
            + 0.0722 * channel(integer & 0xff)
    }

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

    /// The swatch whose hue is nearest to `hue`. A grey or very dim swatch
    /// does not count as usable, and a swatch further than 45 degrees away is
    /// not a match. Nil sends the key to the luminance rule.
    func swatchHex(for hue: Hue) -> String? {
        guard let target = hue.degrees else { return nil }

        var best: (hex: String, distance: Double)?
        for swatch in swatches {
            guard let components = Self.hueComponents(of: swatch),
                  components.saturation >= Self.minimumSwatchSaturation else {
                continue
            }
            let distance = Self.hueDistance(components.hue, target)
            guard distance <= Self.maximumSwatchDistance else { continue }
            if best == nil || distance < best!.distance {
                best = (Self.digits(swatch), distance)
            }
        }
        return best?.hex
    }

    private static let minimumSwatchSaturation = 0.20
    private static let maximumSwatchDistance = 45.0

    private static func digits(_ value: String) -> String {
        value.hasPrefix("#") ? String(value.dropFirst()).lowercased() : value.lowercased()
    }

    private static func hueComponents(of value: String) -> (hue: Double, saturation: Double, lightness: Double)? {
        let digits = digits(value)
        guard digits.count == 6, let integer = UInt32(digits, radix: 16) else { return nil }

        let red = Double((integer >> 16) & 0xff) / 255
        let green = Double((integer >> 8) & 0xff) / 255
        let blue = Double(integer & 0xff) / 255
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let lightness = (maximum + minimum) / 2
        guard maximum != minimum else { return (0, 0, lightness) }

        let delta = maximum - minimum
        let saturation = lightness > 0.5
            ? delta / (2 - maximum - minimum)
            : delta / (maximum + minimum)

        let hue: Double
        switch maximum {
        case red:
            hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        case green:
            hue = (blue - red) / delta + 2
        default:
            hue = (red - green) / delta + 4
        }
        return (hue * 60 < 0 ? hue * 60 + 360 : hue * 60, saturation, lightness)
    }

    private static func hueDistance(_ first: Double, _ second: Double) -> Double {
        let raw = abs(first - second).truncatingRemainder(dividingBy: 360)
        return min(raw, 360 - raw)
    }

    /// Every palette below is copied from the official palette file named in
    /// `sourceURL`. A palette whose values could not be verified is not in
    /// the list.
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
            swatches: ["#8fbcbb", "#88c0d0", "#81a1c1", "#5e81ac", "#b48ead", "#a3be8c", "#ebcb8b", "#d08770", "#bf616a"],
            sourceURL: "https://github.com/nordtheme/nord/blob/develop/src/nord.scss",
            licence: "MIT"
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
            swatches: ["#f38ba8", "#fab387", "#f9e2af", "#a6e3a1", "#74c7ec", "#cba6f7"],
            sourceURL: "https://github.com/catppuccin/nvim/blob/main/lua/catppuccin/palettes/mocha.lua",
            licence: "MIT"
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
            swatches: ["#ed8796", "#f5a97f", "#eed49f", "#a6da95", "#7dc4e4", "#c6a0f6"],
            sourceURL: "https://github.com/catppuccin/nvim/blob/main/lua/catppuccin/palettes/macchiato.lua",
            licence: "MIT"
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
            swatches: ["#e78284", "#ef9f76", "#e5c890", "#a6d189", "#85c1dc", "#ca9ee6"],
            sourceURL: "https://github.com/catppuccin/nvim/blob/main/lua/catppuccin/palettes/frappe.lua",
            licence: "MIT"
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
            swatches: ["#d20f39", "#fe640b", "#df8e1d", "#40a02b", "#209fb5", "#8839ef"],
            sourceURL: "https://github.com/catppuccin/nvim/blob/main/lua/catppuccin/palettes/latte.lua",
            licence: "MIT"
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
            swatches: ["#b58900", "#cb4b16", "#dc322f", "#d33682", "#6c71c4", "#268bd2", "#2aa198", "#859900"],
            sourceURL: "https://github.com/altercation/solarized/blob/master/vim-colors-solarized/colors/solarized.vim",
            licence: "MIT"
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
            swatches: ["#b58900", "#cb4b16", "#dc322f", "#d33682", "#6c71c4", "#268bd2", "#2aa198", "#859900"],
            sourceURL: "https://github.com/altercation/solarized/blob/master/vim-colors-solarized/colors/solarized.vim",
            licence: "MIT"
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
            swatches: ["#e06c75", "#d19a66", "#e5c07b", "#98c379", "#56b6c2", "#61afef", "#c678dd"],
            sourceURL: "https://github.com/atom/one-dark-syntax/blob/master/styles/colors.less",
            licence: "MIT"
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
            swatches: ["#e45649", "#986801", "#c18401", "#50a14f", "#0184bc", "#4078f2", "#a626a4"],
            sourceURL: "https://github.com/atom/one-light-syntax/blob/master/styles/colors.less",
            licence: "MIT"
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
            swatches: ["#ff5555", "#ffb86c", "#f1fa8c", "#50fa7b", "#8be9fd", "#bd93f9", "#ff79c6"],
            sourceURL: "https://github.com/dracula/alacritty/blob/master/dracula.toml",
            licence: "MIT"
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
            swatches: ["#f7768e", "#ff9e64", "#e0af68", "#9ece6a", "#7dcfff", "#7aa2f7", "#bb9af7"],
            sourceURL: "https://github.com/folke/tokyonight.nvim/blob/main/lua/tokyonight/colors/night.lua",
            licence: "Apache-2.0"
        ),
        BarPalette(
            id: "tokyo-night-storm",
            displayName: "Tokyo Night Storm",
            family: "Tokyo Night",
            isDark: true,
            background: "#24283b",
            foreground: "#c0caf5",
            accent: "#7aa2f7",
            accentSecondary: "#bb9af7",
            muted: "#565f89",
            border: "#414868",
            swatches: ["#f7768e", "#ff9e64", "#e0af68", "#9ece6a", "#7dcfff", "#7aa2f7", "#bb9af7"],
            sourceURL: "https://github.com/folke/tokyonight.nvim/blob/main/lua/tokyonight/colors/storm.lua",
            licence: "Apache-2.0"
        ),
        BarPalette(
            id: "tokyo-night-moon",
            displayName: "Tokyo Night Moon",
            family: "Tokyo Night",
            isDark: true,
            background: "#222436",
            foreground: "#c8d3f5",
            accent: "#82aaff",
            accentSecondary: "#c099ff",
            muted: "#636da6",
            border: "#444a73",
            swatches: ["#ff757f", "#ff966c", "#ffc777", "#c3e88d", "#86e1fc", "#82aaff", "#c099ff"],
            sourceURL: "https://github.com/folke/tokyonight.nvim/blob/main/lua/tokyonight/colors/moon.lua",
            licence: "Apache-2.0"
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
            swatches: ["#fb4934", "#fe8019", "#fabd2f", "#b8bb26", "#8ec07c", "#83a598", "#d3869b"],
            sourceURL: "https://github.com/morhetz/gruvbox/blob/master/colors/gruvbox.vim",
            licence: "MIT"
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
            swatches: ["#9d0006", "#af3a03", "#b57614", "#79740e", "#427b58", "#076678", "#8f3f71"],
            sourceURL: "https://github.com/morhetz/gruvbox/blob/master/colors/gruvbox.vim",
            licence: "MIT"
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
            swatches: ["#eb6f92", "#f6c177", "#ebbcba", "#31748f", "#9ccfd8", "#c4a7e7"],
            sourceURL: "https://github.com/rose-pine/palette/blob/main/palette.json",
            licence: "MIT"
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
            swatches: ["#eb6f92", "#f6c177", "#ea9a97", "#3e8fb0", "#9ccfd8", "#c4a7e7"],
            sourceURL: "https://github.com/rose-pine/palette/blob/main/palette.json",
            licence: "MIT"
        ),
        BarPalette(
            id: "rose-pine-dawn",
            displayName: "Rosé Pine Dawn",
            family: "Rosé Pine",
            isDark: false,
            background: "#faf4ed",
            foreground: "#464261",
            accent: "#907aa9",
            accentSecondary: "#56949f",
            muted: "#9893a5",
            border: "#f2e9e1",
            swatches: ["#b4637a", "#ea9d34", "#d7827e", "#286983", "#56949f", "#907aa9"],
            sourceURL: "https://github.com/rose-pine/palette/blob/main/palette.json",
            licence: "MIT"
        ),
        BarPalette(
            id: "everforest-dark",
            displayName: "Everforest Dark",
            family: "Everforest",
            isDark: true,
            background: "#2d353b",
            foreground: "#d3c6aa",
            accent: "#a7c080",
            accentSecondary: "#7fbbb3",
            muted: "#7a8478",
            border: "#343f44",
            swatches: ["#e67e80", "#e69875", "#dbbc7f", "#a7c080", "#83c092", "#7fbbb3", "#d699b6"],
            sourceURL: "https://github.com/sainnhe/everforest/blob/master/autoload/everforest.vim",
            licence: "MIT"
        ),
        BarPalette(
            id: "everforest-light",
            displayName: "Everforest Light",
            family: "Everforest",
            isDark: false,
            background: "#fdf6e3",
            foreground: "#5c6a72",
            accent: "#8da101",
            accentSecondary: "#3a94c5",
            muted: "#a6b0a0",
            border: "#f4f0d9",
            swatches: ["#f85552", "#f57d26", "#dfa000", "#8da101", "#35a77c", "#3a94c5", "#df69ba"],
            sourceURL: "https://github.com/sainnhe/everforest/blob/master/autoload/everforest.vim",
            licence: "MIT"
        ),
        BarPalette(
            id: "kanagawa-wave",
            displayName: "Kanagawa Wave",
            family: "Kanagawa",
            isDark: true,
            background: "#1f1f28",
            foreground: "#dcd7ba",
            accent: "#7e9cd8",
            accentSecondary: "#957fb8",
            muted: "#727169",
            border: "#363646",
            swatches: ["#e46876", "#ffa066", "#e6c384", "#98bb6c", "#7aa89f", "#7e9cd8", "#957fb8", "#d27e99"],
            sourceURL: "https://github.com/rebelot/kanagawa.nvim/blob/master/lua/kanagawa/colors.lua",
            licence: "MIT"
        ),
        BarPalette(
            id: "kanagawa-dragon",
            displayName: "Kanagawa Dragon",
            family: "Kanagawa",
            isDark: true,
            background: "#181616",
            foreground: "#c5c9c5",
            accent: "#8ba4b0",
            accentSecondary: "#8992a7",
            muted: "#7a8382",
            border: "#393836",
            swatches: ["#c4746e", "#b6927b", "#c4b28a", "#87a987", "#8ea4a2", "#8ba4b0", "#8992a7", "#a292a3"],
            sourceURL: "https://github.com/rebelot/kanagawa.nvim/blob/master/lua/kanagawa/colors.lua",
            licence: "MIT"
        ),
        BarPalette(
            id: "ayu-dark",
            displayName: "Ayu Dark",
            family: "Ayu",
            isDark: true,
            background: "#0f1419",
            foreground: "#e6e1cf",
            accent: "#f29718",
            accentSecondary: "#36a3d9",
            muted: "#5c6773",
            border: "#2d3640",
            swatches: ["#f07178", "#ffb454", "#e7c547", "#b8cc52", "#95e6cb", "#36a3d9", "#ffee99"],
            sourceURL: "https://github.com/ayu-theme/ayu-vim/blob/master/colors/ayu.vim",
            licence: "Apache-2.0"
        ),
        BarPalette(
            id: "ayu-light",
            displayName: "Ayu Light",
            family: "Ayu",
            isDark: false,
            background: "#fafafa",
            foreground: "#5c6773",
            accent: "#ff6a00",
            accentSecondary: "#36a3d9",
            muted: "#abb0b6",
            border: "#d9d8d7",
            swatches: ["#f07178", "#f29718", "#e7c547", "#86b300", "#4cbf99", "#36a3d9", "#a37acc"],
            sourceURL: "https://github.com/ayu-theme/ayu-vim/blob/master/colors/ayu.vim",
            licence: "Apache-2.0"
        ),
        BarPalette(
            id: "ayu-mirage",
            displayName: "Ayu Mirage",
            family: "Ayu",
            isDark: true,
            background: "#212733",
            foreground: "#d9d7ce",
            accent: "#ffcc66",
            accentSecondary: "#5ccfe6",
            muted: "#5c6773",
            border: "#343f4c",
            swatches: ["#f07178", "#ffae57", "#ffcc66", "#bbe67e", "#5ccfe6", "#80d4ff", "#d4bfff"],
            sourceURL: "https://github.com/ayu-theme/ayu-vim/blob/master/colors/ayu.vim",
            licence: "Apache-2.0"
        ),
        BarPalette(
            id: "iceberg-dark",
            displayName: "Iceberg Dark",
            family: "Iceberg",
            isDark: true,
            background: "#161821",
            foreground: "#c6c8d1",
            accent: "#84a0c6",
            accentSecondary: "#89b8c2",
            muted: "#6b7089",
            border: "#1e2132",
            swatches: ["#e27878", "#e2a478", "#b4be82", "#89b8c2", "#84a0c6", "#a093c7"],
            sourceURL: "https://github.com/cocopon/iceberg.vim/blob/master/colors/iceberg.vim",
            licence: "MIT"
        ),
        BarPalette(
            id: "monokai",
            displayName: "Monokai",
            family: "Monokai",
            isDark: true,
            background: "#272822",
            foreground: "#f8f8f2",
            accent: "#66d9ef",
            accentSecondary: "#ae81ff",
            muted: "#75715e",
            border: "#383830",
            swatches: ["#f92672", "#fd971f", "#f4bf75", "#a6e22e", "#a1efe4", "#66d9ef", "#ae81ff"],
            sourceURL: "https://github.com/tinted-theming/base16-schemes/blob/main/monokai.yaml",
            licence: "MIT"
        )
    ]
}
