import AppKit
import Foundation

/// The kind of image an icon value points at.
///
/// SketchyBar reads an icon value in three ways: `sf.<name>` is an SF
/// Symbol, `app.<bundle id>` is the icon of an installed app, and
/// `media.artwork` is the artwork of the playing song. Every other value
/// is text, such as an emoji.
enum SketchyBarIconKind: String {
    case symbol
    case appIcon
    case mediaArtwork
    case text
    case unknown
}

/// An icon value of a config, split into the parts the preview needs.
struct SketchyBarIcon: Equatable {
    let kind: SketchyBarIconKind
    /// The name of the SF Symbol, without the `sf.` prefix.
    let symbolName: String?
    /// The bundle identifier of the app whose icon is shown.
    let bundleIdentifier: String?
    /// The text of the icon, such as an emoji.
    let text: String?

    static let unknown = SketchyBarIcon(kind: .unknown, symbolName: nil, bundleIdentifier: nil, text: nil)

    /// Reads an icon value the way SketchyBar reads it.
    static func parse(_ rawValue: String) -> SketchyBarIcon {
        let value = SketchyBarValueRules.unquoted(rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .unknown }

        if value.hasPrefix("sf.") {
            let name = String(value.dropFirst(3))
            guard !name.isEmpty else { return .unknown }
            return SketchyBarIcon(kind: .symbol, symbolName: name, bundleIdentifier: nil, text: nil)
        }

        if value.hasPrefix("app.") {
            let bundle = String(value.dropFirst(4))
            guard !bundle.isEmpty else { return .unknown }
            return SketchyBarIcon(kind: .appIcon, symbolName: nil, bundleIdentifier: bundle, text: nil)
        }

        if value == "media.artwork" {
            return SketchyBarIcon(kind: .mediaArtwork, symbolName: nil, bundleIdentifier: nil, text: nil)
        }

        return SketchyBarIcon(kind: .text, symbolName: nil, bundleIdentifier: nil, text: value)
    }

    /// The key the image of the icon is cached under.
    fileprivate var cacheKey: String {
        switch kind {
        case .symbol: return "sf.\(symbolName ?? "")"
        case .appIcon: return "app.\(bundleIdentifier ?? "")"
        case .mediaArtwork: return "media.artwork"
        case .text: return "text.\(text ?? "")"
        case .unknown: return "unknown"
        }
    }

    /// True when the value can be the bundle identifier of an app.
    ///
    /// A bundle identifier holds a dot, such as `com.apple.Safari`. A
    /// value without one cannot name an app, so the system is never asked
    /// for it.
    static func canBeBundleIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        guard value.contains(".") else { return false }
        return !value.contains(where: { $0.isWhitespace })
    }

    /// True when the image of the icon has to be looked up.
    ///
    /// A value that cannot name an app is never looked up, so a value that
    /// is being typed does not ask the system on every key stroke.
    var needsLookup: Bool {
        switch kind {
        case .symbol: return true
        case .appIcon: return SketchyBarIcon.canBeBundleIdentifier(bundleIdentifier ?? "")
        case .mediaArtwork, .text, .unknown: return false
        }
    }
}

/// The way SketchyBar draws an SF Symbol.
enum SketchyBarSymbolMode: String {
    /// The symbol keeps its own colors.
    case automatic
    /// The symbol is drawn in one color.
    case color
    /// The symbol is drawn in the color of the item.
    case draw
}

/// The images of the icons in the preview.
///
/// Looking up an app icon asks the system for the app, so the result is
/// kept and reused. The cache holds a limited number of entries, so it
/// cannot grow without bound.
final class SketchyBarIconImageCache {
    static let shared = SketchyBarIconImageCache()

    /// The lookup of the image of an icon.
    typealias Lookup = (SketchyBarIcon) -> NSImage?

    /// How many images the cache keeps.
    private static let limit = 64

    private enum Entry {
        case image(NSImage)
        case missing
    }

    private let lookup: Lookup
    private var entries: [String: Entry] = [:]
    /// The keys of the entries, oldest first.
    private var keys: [String] = []
    private let lock = NSLock()

    /// The cache with the lookup of the system.
    ///
    /// The tests use their own lookup, so they never ask the system.
    init(lookup: Lookup? = nil) {
        self.lookup = lookup ?? SketchyBarIconImageCache.systemLookup
    }

    /// The image of an icon, when the system has one.
    func image(for icon: SketchyBarIcon) -> NSImage? {
        guard icon.needsLookup else { return nil }

        let key = icon.cacheKey

        lock.lock()
        let cached = entries[key]
        lock.unlock()

        if let cached {
            switch cached {
            case .image(let image): return image
            case .missing: return nil
            }
        }

        // The lookup asks the system for the app, so it runs without the
        // lock.
        let image = lookup(icon)
        store(image, for: key)
        return image
    }

    /// Keeps the image of an icon and drops the oldest one when the cache
    /// is full.
    private func store(_ image: NSImage?, for key: String) {
        lock.lock()
        defer { lock.unlock() }

        if entries[key] == nil {
            keys.append(key)
        }
        entries[key] = image.map(Entry.image) ?? .missing

        while keys.count > Self.limit {
            entries[keys.removeFirst()] = nil
        }
    }

    /// The image of an icon, read from the system.
    private static func systemLookup(_ icon: SketchyBarIcon) -> NSImage? {
        switch icon.kind {
        case .symbol:
            guard let name = icon.symbolName else { return nil }
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)
        case .appIcon:
            guard let bundle = icon.bundleIdentifier,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)
        case .mediaArtwork, .text, .unknown:
            return nil
        }
    }
}
