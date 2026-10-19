import Foundation

/// Builds the text of a new SketchyBar item file.
///
/// The service is pure: it reads nothing and writes nothing. It knows the
/// templates the wizard offers and writes them the way SketchyBar expects
/// them, so a new item works the first time it is loaded.
///
/// A script driven item sets its own label, because SketchyBar only runs
/// the script and never fills the label by itself.
struct ItemScaffolder {
    /// The way the item file is written.
    enum Style: String, CaseIterable, Identifiable {
        case sbarLua
        case shell

        var id: String { rawValue }

        var title: String {
            switch self {
            case .sbarLua: return "SbarLua"
            case .shell: return "Shell"
            }
        }

        var fileExtension: String {
            switch self {
            case .sbarLua: return "lua"
            case .shell: return "sh"
            }
        }
    }

    /// The shape of an item.
    enum Kind {
        /// A static icon with a label.
        case text
        /// An item whose script fills the label.
        case script
        /// An item that shows the icon of an app.
        case appIcon
        /// An item with nothing but a position.
        case custom
    }

    /// One template of the wizard.
    struct Template: Identifiable {
        let id: String
        let name: String
        let summary: String
        let kind: Kind
        /// The style the template is written in.
        let style: Style
    }

    /// The values a template brings with it.
    private struct Spec {
        let id: String
        let name: String
        let summary: String
        let kind: Kind
        let icon: String
        let updateFreq: Int
        /// The shell command that produces the text of the label.
        let labelCommand: String?
    }

    private static let specs: [Spec] = [
        Spec(
            id: "clock",
            name: "Clock",
            summary: "Shows the time. The script sets the label every minute.",
            kind: .script,
            icon: "sf.clock",
            updateFreq: 60,
            labelCommand: "date '+%H:%M'"
        ),
        Spec(
            id: "battery",
            name: "Battery",
            summary: "Shows the battery level. The script sets the label every ten seconds.",
            kind: .script,
            icon: "sf.battery.100",
            updateFreq: 10,
            labelCommand: "pmset -g batt | grep -Eo '[0-9]+%'"
        ),
        Spec(
            id: "volume",
            name: "Volume",
            summary: "Shows the output volume. The script sets the label every five seconds.",
            kind: .script,
            icon: "sf.volume.2",
            updateFreq: 5,
            labelCommand: "osascript -e 'output volume of (get volume settings)'"
        ),
        Spec(
            id: "wifi",
            name: "Wi-Fi",
            summary: "Shows the name of the Wi-Fi network. The script sets the label every ten seconds.",
            kind: .script,
            icon: "sf.wifi",
            updateFreq: 10,
            labelCommand: "networksetup -getairportnetwork en0 | sed -n \"s/^.*: //p\""
        ),
        Spec(
            id: "media",
            name: "Media",
            summary: "Shows the title of the Spotify track. The script sets the label every five seconds.",
            kind: .script,
            icon: "sf.music.note",
            updateFreq: 5,
            labelCommand: "osascript -e 'tell application \"Spotify\" to get name of current track'"
        ),
        Spec(
            id: "space",
            name: "Space",
            summary: "Shows the current space. The script needs yabai and jq.",
            kind: .script,
            icon: "sf.rectangle.split.3x1",
            updateFreq: 5,
            labelCommand: "yabai -m query --spaces --space | jq -r .index"
        ),
        Spec(
            id: "front_app",
            name: "Front App",
            summary: "Shows the icon of an app and the name of the app in front.",
            kind: .appIcon,
            icon: "app.com.apple.Safari",
            updateFreq: 5,
            labelCommand: "osascript -e 'tell application \"System Events\" to get name of first application process whose frontmost is true'"
        ),
        Spec(
            id: "static",
            name: "Static Text",
            summary: "A fixed icon with a fixed label. No script runs.",
            kind: .text,
            icon: "sf.text.bubble",
            updateFreq: 0,
            labelCommand: nil
        ),
        Spec(
            id: "custom",
            name: "Custom",
            summary: "An empty item with a position. You add the properties yourself.",
            kind: .custom,
            icon: "",
            updateFreq: 0,
            labelCommand: nil
        )
    ]

    /// The templates of the wizard.
    ///
    /// Every template works in both styles, so the list is the same for
    /// both of them.
    func templates(for style: Style) -> [Template] {
        Self.specs.map { spec in
            Template(
                id: spec.id,
                name: spec.name,
                summary: spec.summary,
                kind: spec.kind,
                style: style
            )
        }
    }

    /// The default icon of a template.
    func defaultIcon(for template: Template) -> String {
        Self.specs.first { $0.id == template.id }?.icon ?? ""
    }

    /// The default update frequency of a template, in seconds.
    func defaultUpdateFreq(for template: Template) -> Int {
        Self.specs.first { $0.id == template.id }?.updateFreq ?? 0
    }

    /// The text of a new item file.
    ///
    /// The alias is the name of the item in SketchyBar. The script of a
    /// script driven item sets the label of that same alias, so both always
    /// match.
    func fileContents(
        template: Template,
        alias: String,
        position: String,
        icon: String,
        label: String,
        updateFreq: Int
    ) -> String {
        guard let spec = Self.specs.first(where: { $0.id == template.id }) else { return "" }

        switch template.style {
        case .sbarLua:
            return sbarLuaContents(
                spec: spec,
                alias: alias,
                position: position,
                icon: icon,
                label: label,
                updateFreq: updateFreq
            )
        case .shell:
            return shellContents(
                spec: spec,
                alias: alias,
                position: position,
                icon: icon,
                label: label
            )
        }
    }

    /// The loader line that loads the item file.
    ///
    /// The dotted form is the style of the SbarLua configs: a file at
    /// `items/left/clock.lua` is loaded with `require("items.left.clock")`.
    func loaderLine(for alias: String, relativePath: String, style: Style = .sbarLua) -> String {
        let path = relativePath.trimmingCharacters(in: .whitespaces)
        switch style {
        case .sbarLua:
            var module = path
            if module.hasSuffix(".lua") { module.removeLast(4) }
            module = module.replacingOccurrences(of: "/", with: ".")
            if module.isEmpty { module = alias }
            return "require(\"\(module)\")"
        case .shell:
            return path.isEmpty ? alias : "source \(path)"
        }
    }

    // MARK: - File contents

    private func sbarLuaContents(
        spec: Spec,
        alias: String,
        position: String,
        icon: String,
        label: String,
        updateFreq: Int
    ) -> String {
        var lines: [String] = []
        lines.append("local \(Self.luaName(for: alias)) = sbar.add(\"item\", \"\(Self.luaString(alias))\", {")
        lines.append("\tposition = \"\(Self.luaString(position))\",")

        switch spec.kind {
        case .text:
            lines.append("\ticon = \"\(Self.luaString(icon))\",")
            lines.append("\tlabel = \"\(Self.luaString(label))\",")
        case .script:
            lines.append("\tscript = '\(Self.luaSingleQuoted(Self.setCommand(spec: spec, alias: alias)))',")
        case .appIcon:
            lines.append("\ticon = \"\(Self.luaString(icon))\",")
            lines.append("\tscript = '\(Self.luaSingleQuoted(Self.setCommand(spec: spec, alias: alias)))',")
        case .custom:
            break
        }

        if spec.kind == .script || spec.kind == .appIcon, updateFreq > 0 {
            lines.append("\tupdate_freq = \(updateFreq),")
        }

        lines.append("})")
        return lines.joined(separator: "\n") + "\n"
    }

    private func shellContents(
        spec: Spec,
        alias: String,
        position: String,
        icon: String,
        label: String
    ) -> String {
        var lines: [String] = ["sketchybar --add item \(alias) \(position)"]

        switch spec.kind {
        case .text:
            lines.append(
                "sketchybar --set \(alias) icon=\"\(Self.shellDoubleQuoted(icon))\" label=\"\(Self.shellDoubleQuoted(label))\""
            )
        case .script:
            lines.append("sketchybar --set \(alias) label=\"\(Self.shellSubstitution(spec))\"")
        case .appIcon:
            lines.append(
                "sketchybar --set \(alias) icon=\"\(Self.shellDoubleQuoted(icon))\" label=\"\(Self.shellSubstitution(spec))\""
            )
        case .custom:
            break
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// The command that fills the label of the item.
    private static func setCommand(spec: Spec, alias: String) -> String {
        guard let labelCommand = spec.labelCommand else { return "" }
        return "sketchybar --set \(alias) label=\"$(\(labelCommand))\""
    }

    /// The command substitution that fills the label of the item.
    ///
    /// The command keeps its own quoting: the substitution starts a new
    /// quoting context, so the quotes of the command stay as they are.
    private static func shellSubstitution(_ spec: Spec) -> String {
        guard let labelCommand = spec.labelCommand else { return "" }
        return "$(\(labelCommand))"
    }

    // MARK: - Quoting

    /// The name of the Lua variable that holds the item.
    ///
    /// The alias may hold characters that Lua does not accept in a name, so
    /// they become underscores.
    static func luaName(for alias: String) -> String {
        var name = alias.map { character -> Character in
            character.isLetter || character.isNumber || character == "_" ? character : "_"
        }
        if let first = name.first, first.isNumber { name.insert("_", at: name.startIndex) }
        return String(name)
    }

    /// A value in a double quoted Lua string.
    static func luaString(_ value: String) -> String {
        var text = value.replacingOccurrences(of: "\\", with: "\\\\")
        text = text.replacingOccurrences(of: "\"", with: "\\\"")
        return text
    }

    /// A value in a single quoted Lua string.
    static func luaSingleQuoted(_ value: String) -> String {
        var text = value.replacingOccurrences(of: "\\", with: "\\\\")
        text = text.replacingOccurrences(of: "'", with: "\\'")
        return text
    }

    /// A value in a double quoted shell string.
    static func shellDoubleQuoted(_ value: String) -> String {
        var text = value.replacingOccurrences(of: "\\", with: "\\\\")
        text = text.replacingOccurrences(of: "\"", with: "\\\"")
        return text
    }
}
