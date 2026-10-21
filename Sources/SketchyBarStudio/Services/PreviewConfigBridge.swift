import Foundation

/// Turns a parsed config into the property assignments of the vendored
/// SketchyBar.
///
/// The bridge is the only place that knows how the spelling of a config
/// becomes the value of a SketchyBar property. It reads the config and
/// calls the C API of the preview, so it never writes to disk.
enum PreviewConfigBridge {
    /// The tree of a Lua config.
    static func plan(forLua source: String) -> BarRenderPlan {
        plan(items: SbarLuaItemParser.items(in: source),
             bar: SbarLuaItemParser.bar(in: source),
             defaults: SbarLuaItemParser.defaults(in: source))
    }

    /// The tree of a shell config.
    static func plan(forShell source: String) -> BarRenderPlan {
        let parsed = ShellConfigCommandParser.parse(in: source)
        return plan(items: parsed.items,
                    bar: parsed.bar,
                    defaults: parsed.defaults,
                    warnings: parsed.warnings)
    }

    /// The tree of a parsed config.
    ///
    /// The declarations of an alias are merged into one item, so an alias
    /// is unique in the tree. The properties of the later declarations
    /// follow the properties of the first one, so the last value of a
    /// property wins.
    private static func plan(items: [StructuredItem],
                             bar: StructuredItem?,
                             defaults: StructuredItem?,
                             warnings: [String] = []) -> BarRenderPlan {
        var aliases: [String] = []
        var properties: [String: [BarRenderProperty]] = [:]
        var allWarnings = warnings

        for item in items {
            guard !item.alias.isEmpty else {
                allWarnings.append("An item of the config has no name, so the preview cannot show it.")
                continue
            }
            if properties[item.alias] != nil {
                allWarnings.append("The alias '\(item.alias)' is used more than once. The declarations are merged into one item.")
            } else {
                aliases.append(item.alias)
            }
            properties[item.alias, default: []] += item.values.map { property(of: $0) }
        }

        return BarRenderPlan(
            defaults: (defaults?.values ?? []).map { property(of: $0) },
            bar: (bar?.values ?? []).map { property(of: $0, key: Self.barKey) },
            items: aliases.map { alias in
                BarRenderItemModel(alias: alias, properties: properties[alias] ?? [])
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
    /// added.
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
            let code = SketchyBarPreviewC.addItem(preview, alias: item.alias)
            guard code == SketchyBarPreviewC.Code.ok else {
                let reason = code == SketchyBarPreviewC.Code.itemExists
                    ? "The preview already has an item with that alias."
                    : "The preview refused the item."
                warnings.append("The item '\(item.alias)' was not added. \(reason)")
                continue
            }
            for property in item.properties {
                let code = SketchyBarPreviewC.setItem(preview, alias: item.alias, key: property.key, value: property.value)
                warnings.append(contentsOf: messages(of: preview, code: code, property: property, owner: "the item '\(item.alias)'"))
            }
        }

        return warnings
    }

    /// One property of a parsed value.
    private static func property(of value: StructuredItemValue, key: (String) -> String = { $0 }) -> BarRenderProperty {
        BarRenderProperty(
            key: key(value.keyPath),
            value: PreviewValue.value(for: value.value, keyPath: value.keyPath)
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

/// The value that is sent to the vendored core.
///
/// The vendored parsers read the value as a token and compare it
/// literally, so the value must not keep the spelling of the file: a
/// string that keeps its quotes is not the value the user wrote, and
/// `label = "10:00"` would show the quotes. The parser of the config hands
/// the value of the literal, so the quotes are already gone. What is left
/// is the spelling of SketchyBar: a boolean is `true` or `false`, and the
/// `updates` property is `on`, `off` or `when_shown`.
enum PreviewValue {
    /// The value of a parsed value.
    static func value(for text: String, keyPath: String) -> String {
        SketchyBarValueRules.normalizedDisplayValue(
            SketchyBarValueRules.displayValue(for: text, keyPath: keyPath),
            keyPath: keyPath
        )
    }
}
