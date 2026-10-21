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
/// because it does not fit on one line. The bridge reports every value
/// that is left out, so the user learns what the preview cannot show.
enum SbarLuaItemParser {
    /// Everything the parser reads from one file.
    struct Declarations {
        /// The items of the bar.
        let items: [StructuredItem]
        /// The declarations of the bar.
        let bars: [StructuredItem]
        /// The declarations of the default item.
        let defaults: [StructuredItem]
        /// The things the preview cannot show.
        let warnings: [String]
    }

    /// The items of a Lua file.
    static func items(in source: String) -> [StructuredItem] {
        declarations(in: source).items
    }

    /// The bar declaration of a Lua file.
    ///
    /// The bar has properties of its own, so the key path of a value
    /// starts with `bar.`, such as `bar.position`. The declaration is nil
    /// when the file has no bar.
    static func bar(in source: String) -> StructuredItem? {
        bars(in: source).first
    }

    /// The declarations of the bar of a Lua file.
    ///
    /// A file can call `sbar.bar({…})` more than once, so every call is
    /// read.
    static func bars(in source: String) -> [StructuredItem] {
        declarations(in: source).bars
    }

    /// The declarations of the default item of a Lua file.
    ///
    /// `sbar.default({…})` holds the properties of the default item: the
    /// item every new item inherits from. The values of the table are
    /// qualified key paths, the same as the values of an item table, so
    /// `icon = { font = { size = 11 } }` is the property
    /// `icon.font.size` of the default item. A file can call
    /// `sbar.default({…})` more than once, so every call is read.
    static func defaults(in source: String) -> [StructuredItem] {
        declarations(in: source).defaults
    }

    /// The range of the alias of the first item of the file.
    ///
    /// The range covers the quoted alias, such as `"clock"`. It is nil
    /// when the file has no item, or when the item has no name.
    static func aliasRange(in source: String) -> LuaSourceRange? {
        let result = LuaTableParser.parse(source: source)

        for call in result.calls where call.path == ["sbar", "add"] {
            guard Self.hasTable(call) else { continue }
            guard let alias = Self.alias(of: call), alias.kind == .literal, !alias.alias.isEmpty, alias.argumentIndex >= 0 else { continue }
            guard call.argumentRanges.indices.contains(alias.argumentIndex) else { continue }
            return call.argumentRanges[alias.argumentIndex]
        }

        return nil
    }

    /// Everything the parser reads from one file.
    static func declarations(in source: String) -> Declarations {
        let result = LuaTableParser.parse(source: source)
        var items: [StructuredItem] = []
        var bars: [StructuredItem] = []
        var defaults: [StructuredItem] = []
        var warnings: [String] = []

        for call in result.calls where call.path == ["sbar", "add"] {
            guard let type = Self.type(of: call) else { continue }
            guard type == "item" else {
                // The preview only knows plain items. The other types need
                // the window server or their own setup.
                warnings.append(PreviewWarning.unsupportedType(type, alias: Self.aliasText(of: call)))
                continue
            }
            guard let alias = Self.alias(of: call) else { continue }

            switch alias.kind {
            case .literal:
                break
            case .computed:
                // The name of the item is built by an expression, such as
                // `"menu." .. i`, so the preview cannot know the alias.
                warnings.append(PreviewWarning.expressionAlias())
            case .none:
                // SbarLua names an item without a name `item_<N>`
                // (`src/sketchybar.c:405-407`).
                warnings.append(PreviewWarning.unnamedItem(generated: true))
            }

            guard let declaration = Self.declaration(of: call,
                                                    kind: .item,
                                                    alias: alias.alias,
                                                    keyPath: { $0 }) else { continue }
            items.append(declaration.item)
            warnings.append(contentsOf: declaration.warnings)
        }

        for call in result.calls where call.path == ["sbar", "bar"] {
            guard let declaration = Self.declaration(of: call,
                                                    kind: .bar,
                                                    alias: "bar",
                                                    keyPath: SketchyBarOptionCatalog.barKeyPath) else { continue }
            bars.append(declaration.item)
            warnings.append(contentsOf: declaration.warnings)
        }

        for call in result.calls where call.path == ["sbar", "default"] {
            guard let declaration = Self.declaration(of: call,
                                                    kind: .defaultItem,
                                                    alias: "default",
                                                    keyPath: { $0 }) else { continue }
            defaults.append(declaration.item)
            warnings.append(contentsOf: declaration.warnings)
        }

        return Declarations(items: items, bars: bars, defaults: defaults, warnings: warnings)
    }

    /// A declaration of a call: the values of its table with the key path
    /// of every value, and the values the preview cannot read.
    private struct Declaration {
        /// The item of the declaration.
        let item: StructuredItem
        /// The values that are not a single literal.
        let warnings: [String]
        /// The values that are not a single literal, with the way they
        /// were written.
        let unreadable: [BarRenderUnreadableValue]
    }

    /// A declaration of an item of a Lua file, with the place it was
    /// declared.
    struct DraftDeclaration {
        /// The number of the call of `sbar.add` inside the file.
        ///
        /// The number counts every call of the file, so a call the parser
        /// does not read does not move the calls that follow it. The
        /// resolver counts the calls the same way, so the number and the
        /// file name the same declaration on both sides.
        let index: Int
        /// The alias of the item, empty when the item has no name.
        let alias: String
        /// The values the parser can read.
        let properties: [BarRenderProperty]
        /// The values the parser cannot read, such as an expression.
        let unreadable: [BarRenderUnreadableValue]
    }

    /// The declarations of the items of a Lua file, in the order of the
    /// source.
    ///
    /// The declarations are the ones of the plain items: the parser reads
    /// no other type of item.
    static func draftItems(in source: String) -> [DraftDeclaration] {
        let result = LuaTableParser.parse(source: source)
        var declarations: [DraftDeclaration] = []
        var index = 0

        for call in result.calls where call.path == ["sbar", "add"] {
            let number = index
            index += 1

            guard let type = Self.type(of: call), type == "item" else { continue }
            guard let alias = Self.alias(of: call) else { continue }
            guard let declaration = Self.declaration(of: call,
                                                    kind: .item,
                                                    alias: alias.alias,
                                                    keyPath: { $0 }) else { continue }

            declarations.append(DraftDeclaration(
                index: number,
                alias: alias.alias,
                properties: declaration.item.values.map {
                    BarRenderProperty(key: $0.keyPath,
                                      value: PreviewValue.value(for: $0.value, keyPath: $0.keyPath))
                },
                unreadable: declaration.unreadable
            ))
        }

        return declarations
    }

    /// The declaration of a call: the values of its table with the key path
    /// of every value.
    private static func declaration(of call: LuaCall,
                                    kind: StructuredItemKind,
                                    alias: String,
                                    keyPath: (String) -> String) -> Declaration? {
        guard let table = call.arguments.compactMap({ argument -> LuaTable? in
            if case .table(let table) = argument { return table }
            return nil
        }).first else { return nil }

        var values: [StructuredItemValue] = []
        var warnings: [String] = []
        var unreadable: [BarRenderUnreadableValue] = []

        for entry in table.entries {
            guard !entry.path.isEmpty else { continue }
            let path = keyPath(entry.path.joined(separator: "."))
            guard Self.isEditable(kind: entry.kind) else {
                // Every value of the table is claimed, also the ones that
                // are not a single literal. Without the claim, the plain
                // scan matches the leading literal of an expression, such
                // as the `"popup."` of `"popup." .. name`.
                warnings.append(PreviewWarning.skippedValue(path, kind: entry.kind))
                unreadable.append(BarRenderUnreadableValue(keyPath: path, kind: entry.kind))
                continue
            }
            values.append(
                StructuredItemValue(
                    alias: alias,
                    keyPath: path,
                    rawValue: entry.text,
                    value: Self.value(of: entry),
                    valueStartOffset: entry.valueRange.start,
                    valueEndOffset: entry.valueRange.end
                )
            )
        }

        let excludedRanges = table.entries
            .filter { !Self.isEditable(kind: $0.kind) }
            .map(\.valueRange)

        return Declaration(
            item: StructuredItem(kind: kind, alias: alias, values: values, excludedRanges: excludedRanges),
            warnings: warnings,
            unreadable: unreadable
        )
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
        /// How the alias was written.
        let kind: AliasKind
    }

    /// How the alias of an item was written.
    private enum AliasKind {
        /// A literal name, such as `clock`.
        case literal
        /// A name that is built by an expression, such as `"menu." .. i`.
        case computed
        /// No name at all, such as `sbar.add("item", {…})`.
        case none
    }

    /// The type of an item call, such as `item` or `graph`.
    private static func type(of call: LuaCall) -> String? {
        for argument in call.arguments {
            guard case .literal(.string(let text)) = argument else { continue }
            return text
        }
        return nil
    }

    /// The name of an item call, when the call declares an item.
    private static func alias(of call: LuaCall) -> ItemAlias? {
        guard let type = Self.type(of: call), type == "item" else { return nil }
        var alias: ItemAlias?
        var strings = 0

        for (index, argument) in call.arguments.enumerated() {
            if alias != nil { break }

            switch argument {
            case .literal(.string(let text)):
                // The first string is the type of the item, the second one
                // is its name.
                strings += 1
                guard strings > 1 else { continue }
                alias = ItemAlias(alias: text, argumentIndex: index, kind: .literal)
            case .table:
                // `sbar.add("item", {…})` has no name.
                alias = ItemAlias(alias: "", argumentIndex: -1, kind: .none)
            case .literal(.number), .literal(.boolean):
                // SbarLua only takes a string as the name, so it gives the
                // item a generated name.
                alias = ItemAlias(alias: "", argumentIndex: -1, kind: .none)
            default:
                // The name is built by an expression, such as
                // `"menu." .. i`.
                alias = ItemAlias(alias: "", argumentIndex: -1, kind: .computed)
            }
        }

        return alias ?? ItemAlias(alias: "", argumentIndex: -1, kind: .none)
    }

    /// The name of an item call, whatever the type of the item is.
    private static func aliasText(of call: LuaCall) -> String {
        var strings: [String] = []
        for argument in call.arguments {
            guard case .literal(.string(let text)) = argument else { continue }
            strings.append(text)
        }
        if strings.count > 1 { return strings[1] }
        // The name is not a literal, so the raw text of the argument names
        // the item.
        let arguments = call.arguments
        guard arguments.count > 1 else { return "" }
        if case .other(let text) = arguments[1] { return text }
        return ""
    }

    /// The value of a literal.
    ///
    /// A string in Lua is the text between its quotes, so the quotes are
    /// not part of the value and the escapes of the string are resolved.
    /// Every other literal is its own text.
    private static func value(of entry: LuaTableEntry) -> String {
        guard entry.kind == .string else { return entry.text }
        let text = entry.text
        guard text.count >= 2 else { return text }
        let quote = text.first!
        guard quote == "\"" || quote == "'", text.last == quote else { return text }
        return resolved(String(text.dropFirst().dropLast()))
    }

    /// The text of a string with the escapes of Lua resolved.
    ///
    /// Lua resolves the same escapes in a single quoted string and in a
    /// double quoted string (`lua-5.5.0/src/llex.c:404-464`). A backslash
    /// that starts no escape stays as it is, because Lua refuses such a
    /// string and the preview shows the text the user wrote.
    private static func resolved(_ text: String) -> String {
        var result = ""
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            guard character == "\\" else {
                result.append(character)
                index += 1
                continue
            }

            index += 1
            guard index < characters.count else {
                result.append(character)
                break
            }

            switch characters[index] {
            case "a": result.append("\u{07}"); index += 1
            case "b": result.append("\u{08}"); index += 1
            case "f": result.append("\u{0C}"); index += 1
            case "n": result.append("\n"); index += 1
            case "r": result.append("\r"); index += 1
            case "t": result.append("\t"); index += 1
            case "v": result.append("\u{0B}"); index += 1
            case "\"": result.append("\""); index += 1
            case "'": result.append("'"); index += 1
            case "\\": result.append("\\"); index += 1
            case "\n", "\r":
                // A newline in a string continues the line.
                result.append("\n")
                index += 1
            case "z":
                // `\z` skips the whitespace that follows it.
                index += 1
                while index < characters.count, characters[index].isWhitespace { index += 1 }
            case "x":
                if let escape = Self.hexEscape(characters, after: index) {
                    result.append(escape.character)
                    index = escape.next
                } else {
                    result.append(character)
                    result.append(characters[index])
                    index += 1
                }
            case "u":
                if let escape = Self.unicodeEscape(characters, after: index) {
                    result.append(escape.character)
                    index = escape.next
                } else {
                    result.append(character)
                    result.append(characters[index])
                    index += 1
                }
            default:
                if let escape = Self.decimalEscape(characters, after: index) {
                    result.append(escape.character)
                    index = escape.next
                } else {
                    // A backslash that starts no escape stays as it is.
                    result.append(character)
                    result.append(characters[index])
                    index += 1
                }
            }
        }

        return result
    }

    /// The character of a `\xNN` escape and the index behind it.
    private static func hexEscape(_ characters: [Character], after index: Int) -> (character: Character, next: Int)? {
        let digits = String(characters.dropFirst(index + 1).prefix(2))
        guard digits.count == 2,
              let value = UInt32(digits, radix: 16),
              let scalar = UnicodeScalar(value) else { return nil }
        return (Character(scalar), index + 3)
    }

    /// The character of a `\u{XXXX}` escape and the index behind it.
    private static func unicodeEscape(_ characters: [Character], after index: Int) -> (character: Character, next: Int)? {
        guard index + 1 < characters.count, characters[index + 1] == "{" else { return nil }
        var cursor = index + 2
        var digits = ""
        while cursor < characters.count, characters[cursor] != "}" {
            digits.append(characters[cursor])
            cursor += 1
        }
        guard cursor < characters.count,
              let value = UInt32(digits, radix: 16),
              let scalar = UnicodeScalar(value) else { return nil }
        return (Character(scalar), cursor + 1)
    }

    /// The character of a `\ddd` escape and the index behind it.
    private static func decimalEscape(_ characters: [Character], after index: Int) -> (character: Character, next: Int)? {
        var cursor = index
        var digits = ""
        while cursor < characters.count, digits.count < 3, characters[cursor].isNumber {
            digits.append(characters[cursor])
            cursor += 1
        }
        guard !digits.isEmpty,
              let value = UInt32(digits),
              let scalar = UnicodeScalar(value) else { return nil }
        return (Character(scalar), cursor)
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
