import Foundation

/// Builds the files of a complete new SketchyBar config.
///
/// The service is pure: it reads nothing and writes nothing. It knows the
/// files a new config needs and writes them the way SketchyBar expects
/// them, so the config works the first time SketchyBar loads it.
///
/// The items of the config come from the item scaffolder, so they are
/// written the same way the item wizard writes them.
struct ConfigScaffolder {
    /// The way the config is written.
    typealias Style = ItemScaffolder.Style

    /// One item a new config can start with.
    struct StarterItem: Identifiable, Hashable {
        let id: String
        let name: String
    }

    /// An item of a new config and the place it stands on the bar.
    private struct StarterSpec {
        let item: StarterItem
        let position: String
    }

    private static let starterSpecs: [StarterSpec] = [
        StarterSpec(item: StarterItem(id: "clock", name: "Clock"), position: "left"),
        StarterSpec(item: StarterItem(id: "battery", name: "Battery"), position: "right"),
        StarterSpec(item: StarterItem(id: "volume", name: "Volume"), position: "right"),
        StarterSpec(item: StarterItem(id: "wifi", name: "Wi-Fi"), position: "right"),
        StarterSpec(item: StarterItem(id: "media", name: "Media"), position: "right")
    ]

    /// The items a new config starts with.
    static let defaultStarterItemIDs = ["clock", "battery"]

    /// The items a new config can start with.
    ///
    /// Both styles offer the same items, so the list does not depend on the
    /// style.
    func starterItems(for style: Style) -> [StarterItem] {
        Self.starterSpecs.map(\.item)
    }

    /// The files of a new config, with the path of every file relative to
    /// the root of the config.
    func fileContents(style: Style, starterItems: [StarterItem]) -> [String: String] {
        switch style {
        case .sbarLua: return sbarLuaFiles(starterItems: starterItems)
        case .shell: return shellFiles(starterItems: starterItems)
        }
    }

    // MARK: - The SbarLua files

    private func sbarLuaFiles(starterItems: [StarterItem]) -> [String: String] {
        let itemScaffolder = ItemScaffolder()
        var files: [String: String] = [:]
        var loaderLines: [String] = []

        for starter in starterItems {
            guard let path = itemPath(for: starter),
                  let template = template(for: starter, style: .sbarLua, scaffolder: itemScaffolder) else { continue }
            files[path] = itemFileContents(for: starter, template: template, scaffolder: itemScaffolder)
            loaderLines.append(itemScaffolder.loaderLine(for: starter.id, relativePath: path, style: .sbarLua))
        }

        var initLines: [String] = [
            "-- The entrypoint of the config.",
            "--",
            "-- The SbarLua module is installed in this folder by the SbarLua installer.",
            "package.cpath = package.cpath .. \";\" .. (os.getenv(\"HOME\") or \"\") .. \"/.local/share/sketchybar_lua/?.so\"",
            "",
            "sbar = require(\"sketchybar\")",
            "",
            "sbar.begin_config()",
            "require(\"bar\")",
            "require(\"themes.colors\")",
            "require(\"helpers.icons\")"
        ]
        initLines.append(contentsOf: loaderLines)
        initLines.append("")
        initLines.append("sbar.hotload(true)")
        initLines.append("sbar.end_config()")
        initLines.append("sbar.event_loop()")

        files["init.lua"] = initLines.joined(separator: "\n") + "\n"
        files["sketchybarrc"] = launcherContents
        files["bar.lua"] = barContents
        files["themes/colors.lua"] = colorsContents
        files["helpers/icons.lua"] = iconsContents
        return files
    }

    /// The file SketchyBar runs when it starts.
    ///
    /// SketchyBar only runs `sketchybarrc`, so the Lua entrypoint of the
    /// config is started from there.
    private var launcherContents: String {
        """
        #!/bin/sh
        # SketchyBar runs this file when the bar starts. The config itself is Lua.
        exec lua init.lua

        """
    }

    /// The look of the bar.
    ///
    /// The bar domain of SketchyBar knows `color` and not `background.color`,
    /// because the background of the bar is the background of the bar itself.
    private var barContents: String {
        """
        -- The look of the bar.
        sbar.bar({
        \tposition = "top",
        \tmargin = 4,
        \theight = 28,
        \tcolor = 0x40000000,
        \ttopmost = true,
        \tfont_smoothing = true
        })

        """
    }

    /// The colours of the config.
    private var colorsContents: String {
        """
        -- The colours of the config. Use them in your items:
        --   local colors = require("themes.colors")
        --   color = colors.fg
        return {
        \tbg = 0xff1e1e2e,
        \tfg = 0xffcdd6f4,
        \taccent = 0xff89b4fa,
        \tred = 0xfff38ba8,
        \tgreen = 0xffa6e3a1,
        \tyellow = 0xfff9e2af,
        \tblue = 0xff89b4fa,
        \tmagenta = 0xffcba6f7,
        \tcyan = 0xff94e2d5,
        \tgrey = 0xff6c7086
        }

        """
    }

    /// The icons of the config.
    private var iconsContents: String {
        """
        -- The icons of the config. SketchyBar reads "sf.<name>" as an SF Symbol:
        --   local icons = require("helpers.icons")
        --   icon = icons.clock
        return {
        \tclock = "sf.clock",
        \tbattery = "sf.battery.100",
        \tvolume = "sf.volume.2",
        \twifi = "sf.wifi",
        \tmedia = "sf.music.note"
        }

        """
    }

    // MARK: - The shell files

    private func shellFiles(starterItems: [StarterItem]) -> [String: String] {
        let itemScaffolder = ItemScaffolder()
        var lines: [String] = [
            "#!/bin/sh",
            "# The bar and the items of the config.",
            "",
            "sketchybar --bar position=top margin=4 height=28 color=0x40000000 topmost=true font_smoothing=true",
            ""
        ]

        for starter in starterItems {
            guard let template = template(for: starter, style: .shell, scaffolder: itemScaffolder) else { continue }
            let contents = itemFileContents(for: starter, template: template, scaffolder: itemScaffolder)
            let itemLines = contents.split(separator: "\n").map(String.init)
            guard let setLine = itemLines.last else { continue }

            var block = itemLines
            if template.kind == .script || template.kind == .appIcon {
                // The script of the item runs the line that fills the label
                // again and again, so the label stays fresh.
                let updateFreq = itemScaffolder.defaultUpdateFreq(for: template)
                block.append(
                    "sketchybar --set \(starter.id) update_freq=\(updateFreq) \(Self.shellScriptProperty(for: setLine))"
                )
            }
            lines.append(contentsOf: block)
            lines.append("")
        }

        // The file ends with the last item, without an empty line.
        while lines.last?.isEmpty == true { lines.removeLast() }
        return ["sketchybarrc": lines.joined(separator: "\n") + "\n"]
    }

    /// The script property of a shell item.
    ///
    /// The item scaffoldolder writes the line that fills the label. The
    /// script of the item runs that line again and again, so the label
    /// stays fresh. The quotes and the substitution of the line are
    /// escaped, so they run when SketchyBar runs the script and not when
    /// the config is loaded.
    private static func shellScriptProperty(for setLine: String) -> String {
        let escaped = setLine
            .replacingOccurrences(of: "$(", with: "\\$(")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "script=\"\(escaped)\""
    }

    // MARK: - The items

    /// The path of an item inside the config.
    private func itemPath(for starter: StarterItem) -> String? {
        guard Self.starterSpecs.contains(where: { $0.item.id == starter.id }) else { return nil }
        return "items/\(position(for: starter))/\(starter.id).lua"
    }

    /// The place an item stands on the bar.
    private func position(for starter: StarterItem) -> String {
        Self.starterSpecs.first { $0.item.id == starter.id }?.position ?? "right"
    }

    /// The template of an item.
    private func template(
        for starter: StarterItem,
        style: Style,
        scaffolder: ItemScaffolder
    ) -> ItemScaffolder.Template? {
        scaffolder.templates(for: style).first { $0.id == starter.id }
    }

    /// The text of an item file.
    private func itemFileContents(
        for starter: StarterItem,
        template: ItemScaffolder.Template,
        scaffolder: ItemScaffolder
    ) -> String {
        scaffolder.fileContents(
            template: template,
            alias: starter.id,
            position: position(for: starter),
            icon: scaffolder.defaultIcon(for: template),
            label: "",
            updateFreq: scaffolder.defaultUpdateFreq(for: template)
        )
    }
}
