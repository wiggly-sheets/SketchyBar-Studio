import Foundation

/// Copies the text of an item file with a new name and a new alias.
///
/// The service is pure: it reads no file and writes no file. It knows
/// where the alias of an SbarLua item sits in the source, so a copy of an
/// item changes nothing but the alias. Every other line of the file stays
/// exactly as it was.
struct ItemCloner {
    /// The alias declared in the source file, if it is an SbarLua item or a shell config.
    func sourceAlias(in contents: String) -> String? {
        // Try Lua first
        if let alias = SbarLuaItemParser.items(in: contents).first?.alias, !alias.isEmpty {
            return alias
        }
        // Try shell config
        let parsed = ShellConfigCommandParser.parse(in: contents)
        return parsed.items.first?.alias
    }

    /// The file text with the item alias replaced by `newAlias`.
    ///
    /// Only the alias of the first item changes. A file without an item
    /// comes back unchanged, because there is no alias to replace.
    func clonedContents(of contents: String, newAlias: String) -> String {
        // Try Lua first
        if let range = SbarLuaItemParser.aliasRange(in: contents) {
            return replaceAlias(in: contents, range: range, newAlias: newAlias)
        }
        // Try shell config
        if let range = ShellConfigCommandParser.aliasRange(in: contents) {
            return replaceAlias(in: contents, range: range, newAlias: newAlias)
        }
        return contents
    }

    private func replaceAlias(in contents: String, range: LuaSourceRange, newAlias: String) -> String {
        let characters = Array(contents)
        guard range.start < range.end, range.end <= characters.count else { return contents }

        let firstChar = characters[range.start]
        let isQuoted = firstChar == "\"" || firstChar == "'"

        let contentRange: Range<Int>
        if isQuoted {
            // The range covers the quoted alias, so the quotes stay as they
            // are and only the text between them is replaced.
            contentRange = (range.start + 1)..<(range.end - 1)
        } else {
            // The range covers the unquoted alias directly.
            contentRange = range.start..<range.end
        }
        guard contentRange.lowerBound <= contentRange.upperBound else { return contents }

        let escaped: String
        if isQuoted {
            escaped = firstChar == "'"
                ? ItemScaffolder.luaSingleQuoted(newAlias)
                : ItemScaffolder.luaString(newAlias)
        } else {
            // For unquoted shell aliases, just use the raw alias if safe,
            // otherwise quote it
            if ShellConfigScanner.isSafeUnquotedToken(newAlias) {
                escaped = newAlias
            } else {
                escaped = "\"\(ShellConfigScanner.escapeLiteral(newAlias))\""
            }
        }

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
