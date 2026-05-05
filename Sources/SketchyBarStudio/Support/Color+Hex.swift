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

    static func parse(_ value: String) -> SketchyBarColor? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed
            .replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: "#", with: "")

        guard let integer = UInt64(cleaned, radix: 16) else {
            return nil
        }

        switch cleaned.count {
        case 6:
            return SketchyBarColor(
                red: Double((integer >> 16) & 0xff) / 255,
                green: Double((integer >> 8) & 0xff) / 255,
                blue: Double(integer & 0xff) / 255,
                alpha: 1
            )
        case 8:
            if trimmed.hasPrefix("#") {
                return SketchyBarColor(
                    red: Double((integer >> 24) & 0xff) / 255,
                    green: Double((integer >> 16) & 0xff) / 255,
                    blue: Double((integer >> 8) & 0xff) / 255,
                    alpha: Double(integer & 0xff) / 255
                )
            }

            return SketchyBarColor(
                red: Double((integer >> 16) & 0xff) / 255,
                green: Double((integer >> 8) & 0xff) / 255,
                blue: Double(integer & 0xff) / 255,
                alpha: Double((integer >> 24) & 0xff) / 255
            )
        default:
            return nil
        }
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
