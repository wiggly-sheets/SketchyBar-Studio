import Foundation

/// One value of a parsed SbarLua item.
struct StructuredItemValue: Hashable {
    /// The alias of the item the value belongs to.
    let alias: String
    /// The key path inside the item table, such as `icon.font.size`.
    let keyPath: String
    /// The raw text of the value in the file. A string keeps its quotes.
    let rawValue: String
    /// The value of the literal. A string does not keep its quotes and
    /// its escapes are resolved, so the value is the text the user wrote.
    let value: String
    /// The character range of the value in the file.
    let valueStartOffset: Int
    let valueEndOffset: Int
}

/// The domain a parsed declaration belongs to.
enum StructuredItemKind: Hashable {
    /// An item of the bar, such as `sbar.add("item", "clock", {…})`.
    case item
    /// The bar itself, such as `sbar.bar({…})`.
    case bar
    /// The default item, the item every new item inherits from. It is the
    /// domain of `sbar.default({…})` and of `sketchybar --default`.
    case defaultItem
}

/// One item declaration of a Lua file.
struct StructuredItem: Hashable {
    /// The domain the declaration belongs to.
    let kind: StructuredItemKind
    /// The alias of the item, such as `network.status`.
    let alias: String
    /// The editable values of the item.
    let values: [StructuredItemValue]
    /// The ranges of the values that are not a single literal, such as
    /// `"popup." .. name`. They are not editable, and the plain scan must
    /// not match a literal inside them.
    let excludedRanges: [LuaSourceRange]
}
