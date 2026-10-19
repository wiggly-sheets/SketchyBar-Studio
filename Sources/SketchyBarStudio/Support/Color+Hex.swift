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
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else {
            return "0xffffffff"
        }

        return SketchyBarColor(
            red: converted.redComponent,
            green: converted.greenComponent,
            blue: converted.blueComponent,
            alpha: converted.alphaComponent
        )
        .sketchyBarHex
    }

    private static func byte(_ component: Double) -> Int {
        max(0, min(255, Int((component * 255).rounded())))
    }
}
