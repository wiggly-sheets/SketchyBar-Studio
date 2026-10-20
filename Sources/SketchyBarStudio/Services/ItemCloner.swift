import Foundation

/// Copies the text of an item file with a new name and a new alias.
///
/// The service is pure: it reads no file and writes no file. It knows
/// where the alias of an SbarLua item sits in the source, so a copy of an
/// item changes nothing but the alias. Every other line of the file stays
/// exactly as it was.
struct ItemCloner {
    /// The alias declared in the source file, if it is an SbarLua item.
    func sourceAlias(in contents: String) -> String? {
        guard let alias = SbarLuaItemParser.items(in: contents).first?.alias, !alias.isEmpty else { return nil }
        return alias
    }

    /// The file text with the item alias replaced by `newAlias`.
    ///
    /// Only the alias of the first item changes. A file without an item
    /// comes back unchanged, because there is no alias to replace.
    func clonedContents(of contents: String, newAlias: String) -> String {
        guard let range = SbarLuaItemParser.aliasRange(in: contents) else { return contents }

        let characters = Array(contents)
        guard range.start < range.end, range.end <= characters.count else { return contents }

        // The range covers the quoted alias, so the quotes stay as they
        // are and only the text between them is replaced.
        let quote = characters[range.start]
        let contentRange = (range.start + 1)..<(range.end - 1)
        guard contentRange.lowerBound <= contentRange.upperBound else { return contents }

        let escaped = quote == "'"
            ? ItemScaffolder.luaSingleQuoted(newAlias)
            : ItemScaffolder.luaString(newAlias)

        var result = characters
        result.replaceSubrange(contentRange, with: Array(escaped))
        return String(result)
    }

    /// The relative path of the copy, e.g. items/right/clock-utc.lua
    ///
    /// The folder and the extension of the source are kept, only the name
    /// changes. An empty string comes back when the name is not a safe
    /// file name.
    func copyPath(for sourceRelativePath: String, newName: String) -> String {
        guard isSafeFileName(newName) else { return "" }

        let folder = (sourceRelativePath as NSString).deletingLastPathComponent
        let sourceName = (sourceRelativePath as NSString).lastPathComponent
        let pathExtension = (sourceName as NSString).pathExtension
        let fileName = pathExtension.isEmpty || newName.hasSuffix(".\(pathExtension)")
            ? newName
            : "\(newName).\(pathExtension)"

        return folder.isEmpty ? fileName : "\(folder)/\(fileName)"
    }

    /// True when the name can be used as a file name.
    ///
    /// A safe name holds letters, digits, dashes, underscores and dots. It
    /// has no slash, no space and does not start with a dot.
    func isSafeFileName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix(".") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        return name.rangeOfCharacter(from: allowed.inverted) == nil
    }
}
