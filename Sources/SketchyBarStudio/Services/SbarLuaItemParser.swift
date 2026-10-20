import Foundation

/// Reads the SbarLua item declarations of a Lua file.
///
/// SbarLua declares an item with a call such as
/// `sbar.add("item", "network.status", { position = "right" })`. The values
/// of the item live in a table, so the key of a value is the path to it
/// inside that table, such as `icon.font.size`.
///
/// A value that is not a literal, such as `colors.red`, is not editable and
/// is left out. A long string, such as `[[ ... ]]`, is left out too,
/// because it does not fit on one line.
enum SbarLuaItemParser {
    static func items(in source: String) -> [StructuredItem] {
        let result = LuaTableParser.parse(source: source)
        var items: [StructuredItem] = []

        for call in result.calls where call.path == ["sbar", "add"] {
            guard let table = call.arguments.compactMap({ argument -> LuaTable? in
                if case .table(let table) = argument { return table }
                return nil
            }).first else { continue }

            guard let alias = Self.alias(of: call) else { continue }

            let values = table.entries.compactMap { entry -> StructuredItemValue? in
                guard !entry.path.isEmpty else { return nil }
                guard Self.isEditable(kind: entry.kind) else { return nil }
                return StructuredItemValue(
                    alias: alias.alias,
                    keyPath: entry.path.joined(separator: "."),
                    rawValue: entry.text,
                    valueStartOffset: entry.valueRange.start,
                    valueEndOffset: entry.valueRange.end
                )
            }

            // Every value of the table is claimed, also the ones that are
            // not a single literal. Without the claim, the plain scan
            // matches the leading literal of an expression, such as the
            // `"popup."` of `"popup." .. name`.
            let excludedRanges = table.entries
                .filter { !Self.isEditable(kind: $0.kind) }
                .map(\.valueRange)

            items.append(StructuredItem(alias: alias.alias, values: values, excludedRanges: excludedRanges))
        }

        return items
    }

    /// The bar declaration of a Lua file.
    ///
    /// The bar has properties of its own, so the key path of a value
    /// starts with `bar.`, such as `bar.position`. The declaration is nil
    /// when the file has no bar.
    static func bar(in source: String) -> StructuredItem? {
        let result = LuaTableParser.parse(source: source)

        for call in result.calls where call.path == ["sbar", "bar"] {
            guard let table = call.arguments.compactMap({ argument -> LuaTable? in
                if case .table(let table) = argument { return table }
                return nil
            }).first else { continue }

            let values = table.entries.compactMap { entry -> StructuredItemValue? in
                guard !entry.path.isEmpty else { return nil }
                guard Self.isEditable(kind: entry.kind) else { return nil }
                return StructuredItemValue(
                    alias: "bar",
                    keyPath: SketchyBarOptionCatalog.barKeyPath(for: entry.path.joined(separator: ".")),
                    rawValue: entry.text,
                    valueStartOffset: entry.valueRange.start,
                    valueEndOffset: entry.valueRange.end
                )
            }

            // Every value of the table is claimed, also the ones that are
            // not a single literal, so the plain scan does not match a
            // literal inside an expression.
            let excludedRanges = table.entries
                .filter { !Self.isEditable(kind: $0.kind) }
                .map(\.valueRange)

            return StructuredItem(alias: "bar", values: values, excludedRanges: excludedRanges)
        }

        return nil
    }

    /// The range of the alias of the first item of the file.
    ///
    /// The range covers the quoted alias, such as `"clock"`. It is nil
    /// when the file has no item, or when the item has no name.
    static func aliasRange(in source: String) -> LuaSourceRange? {
        let result = LuaTableParser.parse(source: source)

        for call in result.calls where call.path == ["sbar", "add"] {
            guard Self.hasTable(call) else { continue }
            guard let alias = Self.alias(of: call), !alias.alias.isEmpty, alias.argumentIndex >= 0 else { continue }
            guard call.argumentRanges.indices.contains(alias.argumentIndex) else { continue }
            return call.argumentRanges[alias.argumentIndex]
        }

        return nil
    }

    /// True when the call holds a table, which every item call does.
    private static func hasTable(_ call: LuaCall) -> Bool {
        call.arguments.contains { argument in
            if case .table = argument { return true }
            return false
        }
    }

    /// The name of an item call and the argument that holds it.
    private struct ItemAlias {
        /// The alias of the item. It is empty when the item has no name.
        let alias: String
        /// The index of the argument that holds the alias. It is -1 when
        /// the item has no name.
        let argumentIndex: Int
    }

    /// The alias of an item call, when the call declares an item.
    private static func alias(of call: LuaCall) -> ItemAlias? {
        var kind: String?
        var alias: ItemAlias?

        for (index, argument) in call.arguments.enumerated() {
            guard case .literal(.string(let text)) = argument else { continue }
            if text == "item", kind == nil {
                kind = text
                continue
            }
            if alias == nil {
                alias = ItemAlias(alias: text, argumentIndex: index)
            }
        }

        guard kind == "item" else { return nil }
        // SbarLua also accepts an item without a name, such as
        // `sbar.add("item", { position = "right" })`.
        return alias ?? ItemAlias(alias: "", argumentIndex: -1)
    }

    /// True when the kind of a value is a single literal that the user can
    /// edit. A value that is built by an expression is not a literal, so
    /// the user cannot change it without breaking the file.
    private static func isEditable(kind: LuaLiteralKind) -> Bool {
        switch kind {
        case .string, .number, .boolean:
            return true
        case .expression, .longString, .nilLiteral:
            return false
        }
    }
}
