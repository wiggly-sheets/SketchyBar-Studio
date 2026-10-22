import Foundation
@testable import SketchyBarStudio
import XCTest

final class SourceSyntaxHighlighterTests: XCTestCase {
    // MARK: - Helpers

    private func tokens(_ source: String, _ language: SourceLanguage) -> [SourceToken] {
        SourceSyntaxHighlighter.tokens(in: source, language: language)
    }

    private func text(_ token: SourceToken, in source: String) -> String {
        (source as NSString).substring(with: token.range)
    }

    private func texts(of kind: SourceTokenKind, in source: String, _ language: SourceLanguage) -> [String] {
        tokens(source, language)
            .filter { $0.kind == kind }
            .map { text($0, in: source) }
    }

    private func assertTiles(_ source: String, _ language: SourceLanguage, file: StaticString = #filePath, line: UInt = #line) {
        let tokens = tokens(source, language)
        var location = 0
        for token in tokens {
            XCTAssertEqual(token.range.location, location, "token gap or overlap at \(token.range)", file: file, line: line)
            XCTAssertGreaterThan(token.range.length, 0, "empty token at \(token.range)", file: file, line: line)
            location = NSMaxRange(token.range)
        }
        XCTAssertEqual(location, (source as NSString).length, "tokens do not reach the end", file: file, line: line)
    }

    // MARK: - Lua

    func testLuaKeywords() {
        let source = "local x = true\nif x then return nil end"
        let keywords = texts(of: .keyword, in: source, .lua)
        XCTAssertEqual(keywords, ["local", "true", "if", "then", "return", "nil", "end"])
    }

    func testLuaLineComment() {
        let source = "local x = 1 -- note\nreturn x"
        let comments = texts(of: .comment, in: source, .lua)
        XCTAssertEqual(comments, ["-- note"])
        assertTiles(source, .lua)
    }

    func testLuaBlockComment() {
        let source = "--[[ line one\nline two ]] local x = 1"
        let comments = texts(of: .comment, in: source, .lua)
        XCTAssertEqual(comments, ["--[[ line one\nline two ]]"])
        assertTiles(source, .lua)
    }

    func testLuaQuotedStrings() {
        let source = "local s = \"a \\\" b\" .. 'c'"
        let strings = texts(of: .string, in: source, .lua)
        XCTAssertEqual(strings, ["\"a \\\" b\"", "'c'"])
        assertTiles(source, .lua)
    }

    func testLuaLongString() {
        let source = "local s = [[a\nb]]"
        let strings = texts(of: .string, in: source, .lua)
        XCTAssertEqual(strings, ["[[a\nb]]"])
        assertTiles(source, .lua)
    }

    func testLuaNumbersAndOperators() {
        let source = "local n = 0x1f + 1.5e2 * 3"
        XCTAssertEqual(texts(of: .number, in: source, .lua), ["0x1f", "1.5e2", "3"])
        XCTAssertEqual(texts(of: .operator, in: source, .lua), ["=", "+", "*"])
        XCTAssertEqual(texts(of: .type, in: source, .lua), [])
    }

    // MARK: - Shell

    func testShellCommentAndStrings() {
        let source = "# note\necho \"hi $USER\" 'raw # not a comment'"
        XCTAssertEqual(texts(of: .comment, in: source, .shell), ["# note"])
        XCTAssertEqual(texts(of: .string, in: source, .shell), ["\"hi $USER\"", "'raw # not a comment'"])
        assertTiles(source, .shell)
    }

    func testShellVariables() {
        let source = "echo $HOME ${PATH} $1 $# $?"
        XCTAssertEqual(texts(of: .variable, in: source, .shell), ["$HOME", "${PATH}", "$1", "$#", "$?"])
    }

    func testShellKeywords() {
        let source = "if [ -f x ]; then for i in a; do echo \"$i\"; done; fi"
        let keywords = texts(of: .keyword, in: source, .shell)
        XCTAssertEqual(keywords, ["if", "then", "for", "in", "do", "done", "fi"])
        XCTAssertEqual(texts(of: .flag, in: source, .shell), ["-f"])
        XCTAssertEqual(texts(of: .type, in: source, .shell), ["echo"])
    }

    func testShellCaseKeywords() {
        let source = "case \"$1\" in a) function f { :; }; esac"
        let keywords = texts(of: .keyword, in: source, .shell)
        XCTAssertEqual(keywords, ["case", "in", "function", "esac"])
    }

    // MARK: - Language

    func testSketchybarRCDetection() {
        let luaURL = URL(fileURLWithPath: "/tmp/sketchybarrc")
        let shellURL = URL(fileURLWithPath: "/tmp/.sketchybarrc")
        XCTAssertEqual(
            SourceSyntaxHighlighter.language(for: luaURL, contents: "#!/usr/bin/env lua\nrequire(\"items\")"),
            .lua
        )
        XCTAssertEqual(
            SourceSyntaxHighlighter.language(for: shellURL, contents: "#!/bin/bash\nsketchybar --set foo label=hi"),
            .shell
        )
        XCTAssertEqual(
            SourceSyntaxHighlighter.language(for: luaURL, contents: "#!/bin/sh\n# require(\"items\")\nsketchybar --set foo label=hi"),
            .shell
        )
    }

    func testExtensionWinsOverContents() {
        XCTAssertEqual(
            SourceSyntaxHighlighter.language(for: URL(fileURLWithPath: "/tmp/items.lua"), contents: "#!/bin/bash"),
            .lua
        )
        XCTAssertEqual(
            SourceSyntaxHighlighter.language(for: URL(fileURLWithPath: "/tmp/plugin.sh"), contents: "require(\"items\")"),
            .shell
        )
    }

    func testRangesTileInput() {
        let lua = "#!/usr/bin/env lua\nlocal s = [[a\nb]] --[[ c\nd ]]\nreturn 0x10 + 1.5"
        assertTiles(lua, .lua)
        let shell = "#!/bin/bash\n# note\nfor i in \"$@\"; do echo ${i} -n; done\n"
        assertTiles(shell, .shell)
    }
}
