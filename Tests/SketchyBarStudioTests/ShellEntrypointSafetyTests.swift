import Foundation
@testable import SketchyBarStudio
import XCTest

final class ShellEntrypointSafetyTests: XCTestCase {
    // MARK: - Shell quoting

    func testDoubleQuotedShellValueKeepsItsExpansion() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/env.sh")
        try write("export CONFIG_DIR=\"$HOME/.config/sketchybar\"\n", to: fileURL)
        let scanner = ShellConfigScanner()
        var values = scanner.scan(fileURL: fileURL)

        XCTAssertEqual(values.count, 1)

        values[0].draftValue = "$HOME/.config/sketchybar2"
        try scanner.save(values: values, to: fileURL, rootURL: root)

        XCTAssertEqual(
            try String(contentsOf: fileURL, encoding: .utf8),
            "export CONFIG_DIR=\"$HOME/.config/sketchybar2\"\n"
        )
    }

    func testSingleQuotedShellValueStaysSingleQuotedAndLiteral() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/label.sh")
        try write("LABEL='$HOME'\n", to: fileURL)
        let scanner = ShellConfigScanner()
        var values = scanner.scan(fileURL: fileURL)

        values[0].draftValue = "$HOME2"
        try scanner.save(values: values, to: fileURL, rootURL: root)

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "LABEL='$HOME2'\n")
    }

    func testUnquotedShellValueWithASpaceBecomesDoubleQuoted() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/label.sh")
        try write("LABEL=old\n", to: fileURL)
        let scanner = ShellConfigScanner()
        var values = scanner.scan(fileURL: fileURL)

        values[0].draftValue = "new value"
        try scanner.save(values: values, to: fileURL, rootURL: root)

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "LABEL=\"new value\"\n")
    }

    func testUnquotedShellValueThatIsASafeTokenStaysUnquoted() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/label.sh")
        try write("LABEL=old\n", to: fileURL)
        let scanner = ShellConfigScanner()
        var values = scanner.scan(fileURL: fileURL)

        values[0].draftValue = "new"
        try scanner.save(values: values, to: fileURL, rootURL: root)

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "LABEL=new\n")
    }

    func testShellValueWithALineBreakKeepsTheOriginalFile() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/label.sh")
        try write("LABEL=old\n", to: fileURL)
        let scanner = ShellConfigScanner()
        var values = scanner.scan(fileURL: fileURL)

        values[0].draftValue = "a\nb"
        try scanner.save(values: values, to: fileURL, rootURL: root)

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "LABEL=old\n")
    }

    func testDoubleQuotedShellValueKeepsAnEscapedDollarLiteral() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/label.sh")
        try write(#"LABEL="\$(rm -rf ~)""# + "\n", to: fileURL)
        let scanner = ShellConfigScanner()
        var values = scanner.scan(fileURL: fileURL)

        XCTAssertEqual(values.first?.originalValue, #"\$(rm -rf ~)"#)

        values[0].draftValue = #"\$(rm -rf ~)2"#
        try scanner.save(values: values, to: fileURL, rootURL: root)

        // The escaped dollar stays escaped, so the file never runs a command
        // the original file did not run.
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), #"LABEL="\$(rm -rf ~)2""# + "\n")
    }

    func testUnquotedShellValueDoesNotGainAnExpansion() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/label.sh")
        try write("LABEL=$HOME\n", to: fileURL)
        let scanner = ShellConfigScanner()
        var values = scanner.scan(fileURL: fileURL)

        values[0].draftValue = "$HOME2"
        try scanner.save(values: values, to: fileURL, rootURL: root)

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "LABEL=\"\\$HOME2\"\n")
    }

    // MARK: - Assignments that are no options

    func testLocalAssignmentIsNotReported() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/widget.sh")
        try write("local result=5\n", to: fileURL)

        let values = ShellConfigScanner().scan(fileURL: fileURL)

        XCTAssertTrue(values.isEmpty)
    }

    func testLoopCounterIsNotReported() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/widget.sh")
        try write("count=$((count+1))\n", to: fileURL)

        let values = ShellConfigScanner().scan(fileURL: fileURL)

        XCTAssertTrue(values.isEmpty)
    }

    func testExportedVariableIsReported() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("sketchybarrc")
        try write("export FOO=bar\n", to: fileURL)

        let values = ShellConfigScanner().scan(fileURL: fileURL)

        XCTAssertEqual(values.map(\.keyPath), ["FOO"])
    }

    func testOptionOnTheCommandLineIsReported() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/widget.sh")
        try write("sketchybar --set label=\"x\"\n", to: fileURL)

        let values = ShellConfigScanner().scan(fileURL: fileURL)

        XCTAssertEqual(values.map(\.keyPath), ["label"])
    }

    func testUserArrayIsNotReported() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("sketchybarrc")
        try write("SPACE_ICONS=(\"1\" \"2\")\n", to: fileURL)

        let values = ShellConfigScanner().scan(fileURL: fileURL)

        XCTAssertTrue(values.isEmpty)
    }

    // MARK: - Lua entrypoints

    func testLuaSketchybarrcIsAnEntrypointAndItsRequireCanBeToggled() throws {
        let root = try makeConfigRoot()
        let helpersURL = root.appendingPathComponent("helpers/init.lua")
        try write("return {}\n", to: helpersURL)
        let entrypointURL = root.appendingPathComponent("sketchybarrc")
        try write(
            "#!/usr/bin/env lua\n-- Load the sketchybar-package\nrequire(\"helpers\")\nrequire(\"init\")\n",
            to: entrypointURL
        )

        let service = ConfigActivationService()
        let reference = try XCTUnwrap(service.reference(for: helpersURL, rootURL: root))
        XCTAssertEqual(reference.lineNumber, 3)
        XCTAssertEqual(reference.isActive, true)

        let file = ConfigFile(
            url: helpersURL,
            rootURL: root,
            kind: .lua,
            values: [],
            activationReference: reference
        )
        try service.setActive(false, for: file)

        XCTAssertEqual(
            try String(contentsOf: entrypointURL, encoding: .utf8),
            "#!/usr/bin/env lua\n-- Load the sketchybar-package\n-- require(\"helpers\")\nrequire(\"init\")\n"
        )
    }

    func testShellSketchybarrcStillUsesHashComments() throws {
        let root = try makeConfigRoot()
        let widgetURL = root.appendingPathComponent("widgets/one.lua")
        try write("width = 10\n", to: widgetURL)
        let entrypointURL = root.appendingPathComponent("sketchybarrc")
        try write("#!/bin/sh\nsource widgets/one.lua\n", to: entrypointURL)

        let service = ConfigActivationService()
        let reference = try XCTUnwrap(service.reference(for: widgetURL, rootURL: root))
        XCTAssertEqual(reference.lineNumber, 2)

        let file = ConfigFile(
            url: widgetURL,
            rootURL: root,
            kind: .lua,
            values: [],
            activationReference: reference
        )
        try service.setActive(false, for: file)

        XCTAssertEqual(
            try String(contentsOf: entrypointURL, encoding: .utf8),
            "#!/bin/sh\n# source widgets/one.lua\n"
        )
    }

    func testShellScannerDoesNotQuoteALuaSketchybarrc() throws {
        let root = try makeConfigRoot()
        let entrypointURL = root.appendingPathComponent("sketchybarrc")
        let source = "#!/usr/bin/env lua\nrequire(\"helpers\")\n"
        try write(source, to: entrypointURL)

        let scanner = ShellConfigScanner()
        let values = scanner.scan(fileURL: entrypointURL)

        XCTAssertTrue(values.isEmpty)
        XCTAssertEqual(scanner.updatedContents(values: values, originalContents: source), source)
    }

    // MARK: - Byte-order mark

    func testByteOrderMarkSurvivesAToggle() throws {
        let root = try makeConfigRoot()
        let itemURL = root.appendingPathComponent("items/first.lua")
        try write("width = 10\n", to: itemURL)
        let entrypointURL = root.appendingPathComponent("init.lua")
        try write("\u{FEFF}require(\"items.first\")\n", to: entrypointURL)
        XCTAssertEqual(Array(try Data(contentsOf: entrypointURL).prefix(3)), [0xEF, 0xBB, 0xBF])

        let service = ConfigActivationService()
        let reference = try XCTUnwrap(service.reference(for: itemURL, rootURL: root))
        XCTAssertEqual(reference.lineNumber, 1)

        let file = ConfigFile(
            url: itemURL,
            rootURL: root,
            kind: .lua,
            values: [],
            activationReference: reference
        )
        try service.setActive(false, for: file)

        let data = try Data(contentsOf: entrypointURL)
        XCTAssertEqual(
            Array(data.prefix(3)),
            [0xEF, 0xBB, 0xBF],
            "The byte-order mark must stay in the file"
        )
        XCTAssertEqual(
            try String(contentsOf: entrypointURL, encoding: .utf8),
            "-- require(\"items.first\")\n"
        )
    }

    // MARK: - Profiles

    func testRestoreKeepsTheBackupMirrorOfTheConfigRoot() throws {
        let root = try makeConfigRoot()
        let configRoot = root.appendingPathComponent("config")
        let supportRoot = root.appendingPathComponent("support")
        let itemURL = configRoot.appendingPathComponent("items/battery.lua")
        let backupURL = configRoot.appendingPathComponent("backups/notes.txt")
        try write("width = 42\n", to: itemURL)
        try write("my own notes\n", to: backupURL)

        let service = ProfileArchiveService(appSupportRoot: supportRoot)
        try service.saveProfile(named: "before", from: configRoot, configID: "test")
        let profile = try XCTUnwrap(service.listProfiles(for: "test").first)

        try write("width = 10\n", to: itemURL)
        try service.restore(profile: profile, to: configRoot)

        XCTAssertEqual(try String(contentsOf: itemURL, encoding: .utf8), "width = 42\n")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: backupURL.path),
            "The backups folder of the user must survive a restore"
        )
        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), "my own notes\n")
    }

    func testProfileSnapshotDoesNotCarryTheBackupMirror() throws {
        let root = try makeConfigRoot()
        let configRoot = root.appendingPathComponent("config")
        let supportRoot = root.appendingPathComponent("support")
        try write("width = 42\n", to: configRoot.appendingPathComponent("items/battery.lua"))
        try write("my own notes\n", to: configRoot.appendingPathComponent("backups/notes.txt"))

        let service = ProfileArchiveService(appSupportRoot: supportRoot)
        try service.saveProfile(named: "before", from: configRoot, configID: "test")
        let profile = try XCTUnwrap(service.listProfiles(for: "test").first)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: profile.url.appendingPathComponent("backups").path),
            "A profile must not carry the backup mirror"
        )
    }

    // MARK: - Helpers

    private func makeConfigRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SketchyBarStudioShellEntrypointTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
