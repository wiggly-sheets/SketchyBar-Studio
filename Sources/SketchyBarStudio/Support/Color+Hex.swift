import AppKit
import SwiftUI

extension Color {
    init(hexLike value: String) {
        self = SketchyBarColor.parse(value)?.color ?? .secondary
    }
}

struct SketchyBarColor {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    var sketchyBarHex: String {
        let a = Self.byte(alpha)
        let r = Self.byte(red)
        let g = Self.byte(green)
        let b = Self.byte(blue)
        return String(format: "0x%02x%02x%02x%02x", a, r, g, b)
    }

    /// SketchyBar reads colors as a single 32 bit AARRGGBB word.
    static func parse(_ value: String) -> SketchyBarColor? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var digits = trimmed
        var isHashPrefixed = false
        if digits.hasPrefix("#") {
            digits.removeFirst()
            isHashPrefixed = true
        } else if digits.lowercased().hasPrefix("0x") {
            digits.removeFirst(2)
        }

        guard !digits.isEmpty, digits.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }

        switch digits.count {
        case 3:
            guard isHashPrefixed else { return nil }
            let expanded = digits.map { String(repeating: String($0), count: 2) }.joined()
            return color(from: expanded, alphaByte: 0xff)
        case 6:
            return color(from: digits, alphaByte: 0xff)
        case 8:
            return color(from: digits, alphaByte: nil)
        default:
            return nil
        }
    }

    private static func color(from digits: String, alphaByte: UInt64?) -> SketchyBarColor {
        let integer = UInt64(digits, radix: 16) ?? 0
        let alpha = alphaByte ?? ((integer >> 24) & 0xff)

        return SketchyBarColor(
            red: Double((integer >> 16) & 0xff) / 255,
            green: Double((integer >> 8) & 0xff) / 255,
            blue: Double(integer & 0xff) / 255,
            alpha: Double(alpha) / 255
        )
    }

    static func sketchyBarHex(from color: Color) -> String {
        let bytes = rgbaBytes(from: color)
        return String(format: "0x%02x%02x%02x%02x", bytes.alpha, bytes.red, bytes.green, bytes.blue)
    }

    /// Writes a color in the same format as the value it replaces: the same
    /// prefix and the same number of hex digits. A value that cannot be read
    /// falls back to the SketchyBar default.
    static func hexString(from color: Color, preservingFormatOf original: String) -> String {
        guard SketchyBarColor.parse(original) != nil else {
            return sketchyBarHex(from: color)
        }

        let format = ColorFormat(original)
        let bytes = rgbaBytes(from: color)
        switch format.digitCount {
        case 3:
            return format.prefix + String(format: "%x%x%x", bytes.red / 17, bytes.green / 17, bytes.blue / 17)
        case 6:
            return format.prefix + String(format: "%02x%02x%02x", bytes.red, bytes.green, bytes.blue)
        default:
            return format.prefix + String(format: "%02x%02x%02x%02x", bytes.alpha, bytes.red, bytes.green, bytes.blue)
        }
    }

    private static func rgbaBytes(from color: Color) -> (alpha: Int, red: Int, green: Int, blue: Int) {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else {
            return (255, 255, 255, 255)
        }

        return (
            alpha: byte(converted.alphaComponent),
            red: byte(converted.redComponent),
            green: byte(converted.greenComponent),
            blue: byte(converted.blueComponent)
        )
    }

    private static func byte(_ component: Double) -> Int {
        max(0, min(255, Int((component * 255).rounded())))
    }
}

/// The prefix and the digit count of a color value.
private struct ColorFormat {
    let prefix: String
    let digitCount: Int

    init(_ value: String) {
        let trimmed = SketchyBarValueRules.unquoted(value.trimmingCharacters(in: .whitespacesAndNewlines))
        if trimmed.lowercased().hasPrefix("0x") {
            prefix = String(trimmed.prefix(2))
            digitCount = trimmed.count - 2
        } else if trimmed.hasPrefix("#") {
            prefix = "#"
            digitCount = trimmed.count - 1
        } else {
            prefix = ""
            digitCount = trimmed.count
        }
    }
}
