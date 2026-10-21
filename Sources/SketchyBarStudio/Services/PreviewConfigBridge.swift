import Foundation

/// Turns a parsed config into the property assignments of the vendored
/// SketchyBar.
///
/// The bridge is the only place that knows how the spelling of a config
/// becomes the value of a SketchyBar property. It reads the config and
/// calls the C API of the preview, so it never writes to disk.
enum PreviewConfigBridge {
    /// The style a config is written in.
    enum Style {
        /// The SbarLua style, such as `sbar.add("item", "clock", {…})`.
        case lua
        /// The shell style, such as `sketchybar --add item clock right`.
        case shell
    }

    /// The tree of a Lua config.
    static func plan(forLua source: String) -> BarRenderPlan {
        let file = SbarLuaItemParser.declarations(in: source)
        return plan(style: .lua,
                    items: file.items,
                    bar: file.bars,
                    defaults: file.defaults,
                    warnings: file.warnings)
    }

    /// The tree of a shell config.
    static func plan(forShell source: String) -> BarRenderPlan {
        let parsed = ShellConfigCommandParser.parse(in: source)
        return plan(style: .shell,
                    items: parsed.items,
                    bar: parsed.bar,
                    defaults: parsed.defaults,
                    warnings: parsed.warnings)
    }

    /// The tree of a config root.
    ///
    /// The bridge reads every file of the root and combines the plans, so
    /// the defaults of one file reach the items of another. It never
    /// writes: it only reads the files.
    static func plan(forConfigRoot root: URL) -> BarRenderPlan {
        var combined = BarRenderPlan(defaults: [], bar: [], items: [], warnings: [])

        for file in SketchyBarConfigLocator().configFiles(in: root) {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            // A `.lua` file is Lua. A file without an extension, such as
            // the `sketchybarrc` of the sketchybar-package, is decided by
            // its text.
            let isLua = file.pathExtension.lowercased() == "lua" || LuaSourceDetection.isLua(contents)
            let filePlan = isLua ? plan(forLua: contents) : plan(forShell: contents)
            combined = combined.combined(with: filePlan)
        }

        return combined
    }

    /// The tree of a config root that a real Lua interpreter resolved.
    ///
    /// The parser reads the text of a config. It cannot read a value that
    /// an expression builds, such as `colors.white`, and it cannot know
    /// the order the config loads its files in. This path runs the config
    /// in a real Lua interpreter (`LuaConfigRunner`), so the values are
    /// the values of the config and the order is the order of the load.
    ///
    /// The path is additive: the existing `plan(forConfigRoot:)` stays
    /// the same, and it is the fallback. When the Lua run fails, the plan
    /// of the parser is used and a warning says so.
    static func plan(forLuaConfigRoot root: URL) -> BarRenderPlan {
        guard let entrypoint = LuaConfigRunner.entrypoint(in: root) else {
            return fallback(
                for: root,
                reason: "The config has no Lua entrypoint."
            )
        }

        do {
            let resolved = try LuaConfigRunner.resolve(configRoot: root, entrypoint: entrypoint)
            return plan(fromResolved: resolved)
        } catch {
            return fallback(
                for: root,
                reason: "The config could not be resolved with Lua: \(Self.reason(of: error))"
            )
        }
    }

    /// The plan of the parser, with a warning that says why it is used.
    private static func fallback(for root: URL, reason: String) -> BarRenderPlan {
        let parsed = plan(forConfigRoot: root)
        return BarRenderPlan(
            defaults: parsed.defaults,
            bar: parsed.bar,
            items: parsed.items,
            warnings: parsed.warnings + [PreviewWarning.luaFallback(reason)]
        )
    }

    /// The reason of a failed run.
    private static func reason(of error: Error) -> String {
        if let failure = error as? LuaConfigRunner.Failure {
            return failure.description
        }
        return error.localizedDescription
    }

    /// The tree of a config a Lua interpreter resolved.
    ///
    /// The items follow the order of the load, and the properties of an
    /// item follow the table of the item. The daemon refuses the second
    /// add of an alias (`src/message.c:190-193`), so the item is the one
    /// of the first declaration and the properties of the later
    /// declarations follow it. The type and the trailing argument of the
    /// add command are the ones of the first declaration too, because the
    /// daemon keeps the item of the first add.
    static func plan(fromResolved resolved: LuaConfigRunner.ResolvedConfig) -> BarRenderPlan {
        var aliases: [String] = []
        var properties: [String: [BarRenderProperty]] = [:]
        var kinds: [String: (type: String, argument: String?)] = [:]
        var warnings = [PreviewWarning.luaEntrypoint(resolved.entrypoint)]
        warnings += resolved.warnings

        for item in resolved.items {
            if properties[item.alias] == nil {
                aliases.append(item.alias)
                kinds[item.alias] = (item.type, item.argument)
                warnings.append(contentsOf: PreviewWarning.itemType(item.type,
                                                                     alias: item.alias,
                                                                     argument: item.argument))
            } else {
                warnings.append(PreviewWarning.duplicateAlias(item.alias))
            }
            properties[item.alias, default: []] += item.properties.map { property(of: $0) }
        }

        return BarRenderPlan(
            defaults: resolved.defaults.map { property(of: $0) },
            bar: resolved.bar.map { property(of: $0) },
            items: aliases.map { alias in
                BarRenderItemModel(alias: alias,
                                   properties: properties[alias] ?? [],
                                   type: kinds[alias]?.type ?? "item",
                                   argument: kinds[alias]?.argument ?? nil)
            },
            warnings: warnings
        )
    }

    /// The tree of a parsed config.
    ///
    /// The declarations of an alias are merged into one item, so an alias
    /// is unique in the tree. The daemon refuses the second add of an
    /// alias (`src/message.c:190-193`), so the item is the one of the
    /// first declaration. The properties of the later declarations follow
    /// the properties of the first one, so the last value of a property
    /// wins.
    private static func plan(style: Style,
                              items: [StructuredItem],
                              bar: [StructuredItem],
                              defaults: [StructuredItem],
                              warnings: [String]) -> BarRenderPlan {
        var aliases: [String] = []
        var properties: [String: [BarRenderProperty]] = [:]
        var positions: [String: String] = [:]
        var allWarnings = warnings

        for item in items {
            guard !item.alias.isEmpty else { continue }
            if properties[item.alias] == nil {
                aliases.append(item.alias)
                positions[item.alias] = item.addPosition
            } else {
                allWarnings.append(PreviewWarning.duplicateAlias(item.alias, ignoresSecondPosition: style == .shell))
            }
            properties[item.alias, default: []] += item.values.map { property(of: $0) }
        }

        return BarRenderPlan(
            defaults: defaults.flatMap { $0.values.map { property(of: $0) } },
            bar: bar.flatMap { $0.values.map { property(of: $0, key: Self.barKey) } },
            items: aliases.map { alias in
                BarRenderItemModel(alias: alias,
                                   properties: properties[alias] ?? [],
                                   addPosition: positions[alias])
            },
            warnings: allWarnings
        )
    }

    /// Applies the tree to a preview.
    ///
    /// The default item comes first, because it is a snapshot that every
    /// item inherits when it is created (`src/bar_manager.c:463`,
    /// `src/bar_item.c:68`). A default that comes after an item never
    /// reaches that item, so the defaults are set before the first item is
    /// added. The defaults of a plan that holds several files all come
    /// before the first item of every file.
    ///
    /// The answer of the vendored code is not swallowed: a property that
    /// the vendored parser refuses answers with a message, and the app has
    /// to show the user why the property was refused.
    @discardableResult
    static func apply(_ plan: BarRenderPlan, to preview: OpaquePointer?) -> [String] {
        var warnings = plan.warnings

        for property in plan.defaults {
            let code = SketchyBarPreviewC.setDefault(preview, key: property.key, value: property.value)
            warnings.append(contentsOf: messages(of: preview, code: code, property: property, owner: "the default item"))
        }

        for property in plan.bar {
            let code = SketchyBarPreviewC.setBar(preview, key: property.key, value: property.value)
            warnings.append(contentsOf: messages(of: preview, code: code, property: property, owner: "the bar"))
        }

        for item in plan.items {
            if item.type == "event" {
                // The daemon registers a custom event and creates no item
                // for it (`src/message.c:175-185`).
                continue
            }

            let position = Self.addPosition(of: item)
            let code = SketchyBarPreviewC.addItem(preview,
                                                  alias: item.alias,
                                                  type: item.type,
                                                  position: position,
                                                  argument: item.argument)
            if code == SketchyBarPreviewC.Code.itemExists {
                // The daemon refuses the second add of an alias
                // (`src/message.c:190-193`). The properties that follow
                // still apply to the item, so they are sent.
                warnings.append(PreviewWarning.duplicateAlias(item.alias))
            } else if code != SketchyBarPreviewC.Code.ok {
                // The daemon creates the item and removes it again when the
                // position of the add command is illegal
                // (`src/message.c:202-208`), and so does the preview.
                warnings.append("The item '\(item.alias)' was not added. \(Self.message(of: preview))")
                continue
            } else {
                // The daemon says so when the type of the add command is
                // unknown, and the item becomes a plain item
                // (`src/message.c:196-200`).
                let message = Self.message(of: preview)
                if !message.isEmpty {
                    warnings.append(message)
                }
            }

            if code == SketchyBarPreviewC.Code.ok, let position = item.addPosition {
                let property = BarRenderProperty(key: "position", value: position)
                let code = SketchyBarPreviewC.setItem(preview, alias: item.alias, key: property.key, value: property.value)
                warnings.append(contentsOf: messages(of: preview, code: code, property: property, owner: "the item '\(item.alias)'"))
            }

            for property in item.properties {
                let code = SketchyBarPreviewC.setItem(preview, alias: item.alias, key: property.key, value: property.value)
                warnings.append(contentsOf: messages(of: preview, code: code, property: property, owner: "the item '\(item.alias)'"))
            }
        }

        return warnings
    }

    /// The position of the add command of an item.
    ///
    /// The shell style carries the position in the add command
    /// (`sketchybar --add item x right`), and the SbarLua style carries it
    /// in the table of the item (`sbar.add("item", "x", { position = "right" })`).
    /// The daemon removes an item whose add position is missing or illegal
    /// (`src/message.c:202-208`), so the position of the add command is
    /// always sent. The last value of the position wins, like every other
    /// property of an item.
    ///
    /// A config of the SbarLua style can leave the position out. The daemon
    /// removes such an item, but the preview shows it at the position of the
    /// default item, which is the position the preview has always given it.
    private static func addPosition(of item: BarRenderItemModel) -> String {
        if let position = item.addPosition { return position }
        if let position = item.properties.last(where: { $0.key == "position" })?.value { return position }
        return "left"
    }

    /// One property of a parsed value.
    private static func property(of value: StructuredItemValue, key: (String) -> String = { $0 }) -> BarRenderProperty {
        BarRenderProperty(
            key: key(value.keyPath),
            value: PreviewValue.value(for: value.value, keyPath: value.keyPath)
        )
    }

    /// One property of a value a Lua interpreter resolved.
    private static func property(of value: LuaConfigRunner.ResolvedProperty) -> BarRenderProperty {
        BarRenderProperty(
            key: value.key,
            value: PreviewValue.value(for: value.text, keyPath: value.key)
        )
    }

    /// The key of a bar property.
    ///
    /// The app prefixes the key path of a bar value with `bar.`, so the
    /// editor can tell the bar level from the item level. The C API wants
    /// the plain name of the property.
    private static func barKey(_ keyPath: String) -> String {
        keyPath.hasPrefix("bar.") ? String(keyPath.dropFirst(4)) : keyPath
    }

    /// The warnings of one property: the answer of the vendored code and
    /// the message it wrote.
    private static func messages(of preview: OpaquePointer?,
                                 code: Int32,
                                 property: BarRenderProperty,
                                 owner: String) -> [String] {
        let text = Self.message(of: preview)
        guard code != SketchyBarPreviewC.Code.ok || !text.isEmpty else { return [] }
        let reason = text.isEmpty ? "the property was refused" : text
        return ["The property '\(property.key)' of \(owner) was refused: \(reason)"]
    }

    /// The message the vendored code wrote, without the empty lines.
    private static func message(of preview: OpaquePointer?) -> String {
        SketchyBarPreviewC.messages(preview).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The wording of the warnings the bridge produces.
///
/// The wording lives here, so the Lua path and the shell path say the
/// same thing about the same problem.
enum PreviewWarning {
    /// An item type the parser path drops.
    ///
    /// The parsers of the app cannot read the type of an item, so the
    /// parser path drops the item and the preview never shows it. The Lua
    /// path reads the type and keeps the item. The wording of the type is
    /// the same on both paths, and the difference between the paths is in
    /// the sentence that follows it.
    static func unsupportedType(_ type: String, alias: String) -> String {
        let described = typeDescription(type, alias: alias, argument: nil)
            ?? "The preview cannot show the '\(type)' item '\(alias)'."
        return "\(described) \(pathSentence(type, parserPath: true))"
    }

    /// The warnings of the type of an item.
    ///
    /// The daemon has an item for every type but the event
    /// (`src/message.c:175-185`), and the preview shows what it can show
    /// of an item and says what it cannot.
    ///
    /// A type the daemon does not know is not a warning here: the daemon
    /// makes the item a plain item and says so (`src/message.c:196-200`),
    /// and so does the preview.
    static func itemType(_ type: String, alias: String, argument: String?) -> [String] {
        if type == "item" { return [] }
        guard let described = typeDescription(type, alias: alias, argument: argument) else { return [] }
        let sentence = pathSentence(type, parserPath: false)
        return sentence.isEmpty ? [described] : ["\(described) \(sentence)"]
    }

    /// What a type of item shows, in the words that both paths share.
    ///
    /// The wording does not say what the preview does with the item, so
    /// the same words are true on the path that keeps the item and on the
    /// path that drops it.
    private static func typeDescription(_ type: String, alias: String, argument: String?) -> String? {
        switch type {
        case "alias":
            return "The 'alias' item '\(alias)' shows the picture of a menu bar item, which the preview cannot capture."
        case "space":
            return "The 'space' item '\(alias)' shows the picture of a space, which the preview cannot capture."
        case "graph":
            return "The 'graph' item '\(alias)' shows no values yet, because the values come from the script that pushes them."
        case "slider":
            return "The 'slider' item '\(alias)' shows no value yet, because the value comes from the script that pushes it."
        case "bracket":
            return "The 'bracket' item '\(alias)' draws a background around \(members(of: argument))."
        case "event":
            return "The 'event' item '\(alias)' is not shown on the bar, because SketchyBar registers the event and draws nothing for it."
        default:
            return nil
        }
    }

    /// What the path does with an item of a type.
    ///
    /// The two paths differ: the parser path drops the item, and the Lua
    /// path keeps it and shows what it can show of it. The difference is
    /// in this sentence, so the wording of the type stays the same.
    private static func pathSentence(_ type: String, parserPath: Bool) -> String {
        // The daemon creates no item for an event, so nothing of it reaches
        // the preview on either path.
        if type == "event" { return "" }
        if parserPath {
            return "The parser of the app cannot read the type of this item, so the preview does not show it."
        }
        switch type {
        case "alias", "space":
            return "The preview shows it as a placeholder."
        case "graph", "slider":
            return "The preview lays it out with the width of the config."
        case "bracket":
            return "The preview groups the members and draws that background around them."
        default:
            return ""
        }
    }

    /// The members of a bracket, the way a warning names them.
    ///
    /// A bracket draws a background around the items it groups
    /// (`src/group.c:109-138`). The parser path does not read the members
    /// of a bracket, so it names them without the list.
    private static func members(of argument: String?) -> String {
        let names = (argument ?? "").split(separator: " ").map(String.init)
        guard !names.isEmpty else { return "the items it groups" }
        return "the items " + names.map { "'\($0)'" }.joined(separator: ", ")
    }

    /// A value the preview cannot read.
    ///
    /// A value that is built by an expression, such as `colors.red`, needs
    /// a Lua interpreter, so the preview keeps the value SketchyBar has by
    /// default and names the value in its warnings.
    static func skippedValue(_ keyPath: String, kind: LuaLiteralKind) -> String {
        let reason: String
        switch kind {
        case .expression:
            reason = "is built by an expression"
        case .longString:
            reason = "is a long string"
        case .nilLiteral:
            reason = "is nil"
        case .string, .number, .boolean:
            return ""
        }
        return "The value of '\(keyPath)' \(reason), so the preview shows the value SketchyBar has by default, not the value of the config."
    }

    /// The alias of an item that is built by an expression.
    static func expressionAlias() -> String {
        "The alias of an item is built by an expression, so the preview cannot show the item. SketchyBar shows it under the name of the expression."
    }

    /// An item without a name.
    ///
    /// SbarLua names an item without a name `item_<N>`, with a counter of
    /// the process (`src/sketchybar.c:405-407`).
    static func unnamedItem(generated: Bool) -> String {
        if generated {
            return "The item has no name. SketchyBar gives it a generated name (item_0, item_1, ...), so the preview cannot show it."
        }
        return "The item has no name, so SketchyBar does not keep it and the preview cannot show it."
    }

    /// An alias that is added twice.
    ///
    /// The daemon refuses the second add of an alias
    /// (`src/message.c:190-193`), so the item is the one of the first
    /// declaration. The properties of the later declarations are applied
    /// to it, and the last value of a property wins.
    ///
    /// The shell style carries the position in the add command, and the
    /// daemon refuses the whole second add, so the position of the second
    /// add is ignored.
    static func duplicateAlias(_ alias: String, ignoresSecondPosition: Bool = false) -> String {
        var warning = "The alias '\(alias)' is added twice. SketchyBar keeps the first item; the properties of the second declaration are applied, and the last value of a property wins."
        if ignoresSecondPosition {
            warning += " The position of the second add is ignored."
        }
        return warning
    }

    /// A property that the shell builds.
    static func dynamicValue(_ keyPath: String) -> String {
        "The value of '\(keyPath)' is built by the shell, so the preview shows the value SketchyBar has by default, not the value of the config."
    }

    /// An item that is set but never added.
    static func setWithoutAdd(_ alias: String) -> String {
        "The item '\(alias)' is set but never added, so the preview cannot show it."
    }

    /// An item that is added without a position.
    ///
    /// The daemon creates the item and removes it again
    /// (`src/message.c:202-208`).
    static func addWithoutPosition(_ alias: String) -> String {
        "The item '\(alias)' is added without a position, so SketchyBar removes it and the preview cannot show it."
    }

    /// A file that holds no call of the SketchyBar binary.
    static func noSketchyBarCommand() -> String {
        "The file holds no SketchyBar command, so it adds nothing to the preview."
    }

    /// The config was not resolved with Lua, so the parser path was used.
    static func luaFallback(_ reason: String) -> String {
        "The config was not resolved with Lua, so the preview shows the values the parser can read. \(reason)"
    }

    /// The file the Lua path ran.
    ///
    /// The daemon runs the config file through the shell (`exec_config_file`,
    /// `src/hotload.c`), so the file the preview runs is a guess: the
    /// preview runs the `sketchybarrc` when that file is Lua, and the
    /// `init.lua` of the config otherwise. The user has to know which file
    /// the preview ran.
    static func luaEntrypoint(_ name: String) -> String {
        if name == "sketchybarrc" {
            return "The preview ran the 'sketchybarrc' of the config as its entrypoint, because that file is Lua."
        }
        return "The preview ran '\(name)' as the entrypoint of the config, because the 'sketchybarrc' of the config is not a Lua file. The daemon runs the 'sketchybarrc' through the shell, so the preview may have resolved a different config."
    }
}

/// The value that is sent to the vendored core.
///
/// The vendored parsers read the value as a token and compare it
/// literally, so the value must not keep the spelling of the file: a
/// string that keeps its quotes is not the value the user wrote, and
/// `label = "10:00"` would show the quotes. The parser of the config hands
/// the value of the literal, so the quotes are already gone and they are
/// not removed a second time: `label = { string = "\"10:00\"" }` holds the
/// text `"10:00"`, and that is the text the bar shows. What is left is the
/// spelling of SketchyBar: a boolean is `true` or `false`, and the
/// `updates` property is `on`, `off` or `when_shown`.
enum PreviewValue {
    /// The value of a parsed value.
    static func value(for text: String, keyPath: String) -> String {
        let normalized = SketchyBarBoolean.isBooleanKey(keyPath)
            ? (SketchyBarBoolean.normalized(text) ?? text)
            : text
        return SketchyBarValueRules.normalizedDisplayValue(normalized, keyPath: keyPath)
    }
}
