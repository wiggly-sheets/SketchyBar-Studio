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

            var kind: String?
            var name: String?
            for argument in call.arguments {
                guard case .literal(.string(let text)) = argument else { continue }
                if text == "item", kind == nil {
                    kind = text
                    continue
                }
                if name == nil {
                    name = text
                }
            }

            guard kind == "item" else { continue }

            // SbarLua also accepts an item without a name, such as
            // `sbar.add("item", { position = "right" })`.
            let alias = name ?? ""

            let values = table.entries.compactMap { entry -> StructuredItemValue? in
                guard !entry.path.isEmpty else { return nil }
                guard Self.isEditable(kind: entry.kind) else { return nil }
                return StructuredItemValue(
                    alias: alias,
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

            items.append(StructuredItem(alias: alias, values: values, excludedRanges: excludedRanges))
        }

        return items
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
