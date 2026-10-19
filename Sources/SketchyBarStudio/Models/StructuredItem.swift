import Foundation

/// One value of a parsed SbarLua item.
struct StructuredItemValue: Hashable {
    /// The alias of the item the value belongs to.
    let alias: String
    /// The key path inside the item table, such as `icon.font.size`.
    let keyPath: String
    /// The raw text of the value in the file. A string keeps its quotes.
    let rawValue: String
    /// The character range of the value in the file.
    let valueStartOffset: Int
    let valueEndOffset: Int
}

/// One item declaration of a Lua file.
struct StructuredItem: Hashable {
    /// The alias of the item, such as `network.status`.
    let alias: String
    /// The editable values of the item.
    let values: [StructuredItemValue]
    /// The ranges of the values that are not a single literal, such as
    /// `"popup." .. name`. They are not editable, and the plain scan must
    /// not match a literal inside them.
    let excludedRanges: [LuaSourceRange]
}
