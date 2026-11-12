import Foundation

/// Detects whether a config file holds Lua code.
///
/// The file extension is not enough: the `sketchybarrc` of the
/// sketchybar-package is a Lua script without a `.lua` extension.
enum LuaSourceDetection {
    private static let luaShebangRegex = try? NSRegularExpression(
        pattern: #"^#!.*\b(lua|lua\d+(?:\.\d+)*|luajit)\b"#
    )
    private static let shellShebangRegex = try? NSRegularExpression(
        pattern: #"^#!.*\b(bash|sh|zsh|dash|ksh)\b"#
    )
    /// A call that only a Lua config makes: `require("items")` or
    /// `require "items"`.
    private static let luaCallRegex = try? NSRegularExpression(
        pattern: #"\b(require|dofile|loadfile)\s*(\(|["'])"#
    )

    /// True when the contents are a Lua script.
    ///
    /// A Lua shebang decides it. Without a shebang the file is only Lua when
    /// it calls a Lua module and does not claim to be a shell script.
    static func isLua(_ contents: String) -> Bool {
        let text = contents.hasPrefix("\u{FEFF}") ? String(contents.dropFirst()) : contents
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""

        if matches(luaShebangRegex, firstLine) { return true }
        if matches(shellShebangRegex, firstLine) { return false }
        // A line that starts with `#` outside a Lua string or long string is
        // a shell comment. Lua comments start with `--`, so a `require(`
        // inside such a line does not make the file Lua.
        let regions = SourceRegions.luaCodeRegions(in: text)
        var hasShellCommentLine = false
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            let line = text[lineRange]
            guard let first = line.firstIndex(where: { !$0.isWhitespace }), line[first] == "#" else { return }
            let offset = text.distance(from: text.startIndex, to: first)
            if !regions.contains(where: { $0.intersects(offset, offset + 1) }) {
                hasShellCommentLine = true
            }
        }
        if hasShellCommentLine { return false }
        // A `require(` inside a comment or a string does not make a shell
        // file Lua, so the call is only read where it is code.
        return matchesOutsideIgnoredRegions(luaCallRegex, text, regions: regions)
    }

    private static func matches(_ regex: NSRegularExpression?, _ text: String) -> Bool {
        guard let regex else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    private static func matchesOutsideIgnoredRegions(_ regex: NSRegularExpression?,
                                                     _ text: String,
                                                     regions: [SourceRegions.Region]) -> Bool {
        guard let regex else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let start = text.distance(from: text.startIndex, to: matchRange.lowerBound)
            if !regions.contains(where: { $0.intersects(start, start + 1) }) {
                return true
            }
        }
        return false
    }
}
