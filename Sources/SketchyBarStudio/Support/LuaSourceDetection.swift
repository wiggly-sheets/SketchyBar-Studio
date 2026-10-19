import Foundation

/// Detects whether a config file holds Lua code.
///
/// The file extension is not enough: the `sketchybarrc` of the
/// sketchybar-package is a Lua script without a `.lua` extension.
enum LuaSourceDetection {
    private static let luaShebangRegex = try? NSRegularExpression(
        pattern: #"^#!.*\b(lua|luajit)\b"#
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
        return matches(luaCallRegex, text)
    }

    private static func matches(_ regex: NSRegularExpression?, _ text: String) -> Bool {
        guard let regex else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}
