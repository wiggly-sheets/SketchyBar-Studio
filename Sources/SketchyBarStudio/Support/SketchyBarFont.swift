import AppKit
import Foundation

struct SketchyBarFont {
    let family: String
    let style: String
    let size: Double

    var sketchyBarValue: String {
        "\(family):\(style):\(String(format: "%.1f", size))"
    }

    var nsFont: NSFont {
        NSFontManager.shared.font(
            withFamily: family,
            traits: [],
            weight: 5,
            size: CGFloat(size)
        ) ?? NSFont.systemFont(ofSize: CGFloat(size))
    }

    /// The font of a family and a style.
    ///
    /// The style of the config is matched to the style of the font, so
    /// `Bold` gives the bold member of the family. The system font is the
    /// fallback when the family is not installed.
    static func nsFont(family: String, style: String, size: Double) -> NSFont {
        let pointSize = CGFloat(size)
        let familyName = family.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !familyName.isEmpty else { return NSFont.systemFont(ofSize: pointSize) }

        let member = NSFontManager.shared.availableMembers(ofFontFamily: familyName)?.first { member in
            guard member.count > 1, let memberStyle = member[1] as? String else { return false }
            return memberStyle.caseInsensitiveCompare(style) == .orderedSame
        }
        let traits = member.map { NSFontTraitMask(rawValue: ($0[3] as? UInt) ?? 0) } ?? []
        let weight = member.flatMap { $0[2] as? Int } ?? 5

        return NSFontManager.shared.font(withFamily: familyName, traits: traits, weight: weight, size: pointSize)
            ?? NSFont.systemFont(ofSize: pointSize)
    }

    static func parse(_ value: String) -> SketchyBarFont? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let size = Double(parts[2]) else {
            return nil
        }

        return SketchyBarFont(family: parts[0], style: parts[1], size: size)
    }

    static func value(from font: NSFont, for keyPath: String, currentValue: String) -> String {
        let leaf = keyPath.lowercased().split(separator: ".").last.map(String.init) ?? keyPath.lowercased()
        let family = font.familyName ?? font.displayName ?? font.fontName
        let style = font.fontDescriptor.object(forKey: .face) as? String ?? "Regular"
        let size = Double(font.pointSize)

        switch leaf {
        case "family":
            return family
        case "style":
            return style
        case "size":
            return String(format: "%.1f", size)
        default:
            return SketchyBarFont(family: family, style: style, size: size).sketchyBarValue
        }
    }

    static func initialFont(from value: String, keyPath: String) -> NSFont {
        if let fullFont = parse(value) {
            return fullFont.nsFont
        }

        let leaf = keyPath.lowercased().split(separator: ".").last.map(String.init) ?? keyPath.lowercased()
        switch leaf {
        case "family":
            return NSFontManager.shared.font(withFamily: value, traits: [], weight: 5, size: 14) ?? NSFont.systemFont(ofSize: 14)
        case "size":
            return NSFont.systemFont(ofSize: CGFloat(Double(value) ?? 14))
        default:
            return NSFont.systemFont(ofSize: 14)
        }
    }
}
