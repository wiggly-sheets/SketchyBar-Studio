import Foundation
@testable import SketchyBarStudio
import XCTest

final class BarThemeTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName = ""

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "BarThemeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        super.tearDown()
    }

    func testDetectFindsPointerTheme() throws {
        let root = try makeConfigRoot()
        try writeTheme(name: "Sample", to: root)
        try write("Sample\n", to: root.appendingPathComponent("themes/current_theme"))

        let service = makeService(root)

        XCTAssertEqual(service.detect(), .themedPointer(name: "Sample"))
        XCTAssertEqual(service.activeTheme()?.name, "Sample")
    }

    func testDetectReportsMissingThemesFolder() throws {
        let root = try makeConfigRoot()
        let service = makeService(root)

        XCTAssertEqual(service.detect(), .noThemesFolder)
        XCTAssertNil(service.activeTheme())
    }

    func testDetectReportsMissingPointerFile() throws {
        let root = try makeConfigRoot()
        try writeTheme(name: "Sample", to: root)

        let service = makeService(root)

        XCTAssertEqual(service.detect(), .themedPointerMissing)
    }

    func testApplyWritesSameKeysInSameOrderAndMovesPointer() throws {
        let root = try makeConfigRoot()
        try writeTheme(name: "Sample", to: root)
        try write("Sample\n", to: root.appendingPathComponent("themes/current_theme"))
        let service = makeService(root)
        let active = try XCTUnwrap(service.activeTheme())

        let result = try service.apply(nord)

        XCTAssertEqual(result, BarThemeApplyResult(themeName: "Nord", wroteThemeFile: true, wrotePointer: true))
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("themes/current_theme"), encoding: .utf8),
            "Nord\n"
        )
        let written = try String(contentsOf: root.appendingPathComponent("themes/Nord.lua"), encoding: .utf8)
        XCTAssertEqual(
            BarThemeService.hexEntries(in: written).map(\.key),
            active.entries.map(\.key)
        )
        XCTAssertEqual(
            try String(
                contentsOf: root.appendingPathComponent("backups/.sketchybar-studio/themes/current_theme"),
                encoding: .utf8
            ),
            "Sample\n"
        )
    }

    func testApplyKeepsAlphaBytes() throws {
        let root = try makeConfigRoot()
        try write(
            """
            return {
            \tbackground = 0x44112233,
            \tforeground = 0xffabcdef,
            \thover = 0x40FFFFFF,
            }
            """,
            to: root.appendingPathComponent("themes/Sample.lua")
        )
        try write("Sample\n", to: root.appendingPathComponent("themes/current_theme"))

        try makeService(root).apply(nord)

        let written = try String(contentsOf: root.appendingPathComponent("themes/Nord.lua"), encoding: .utf8)
        XCTAssertTrue(written.contains("background = 0x442e3440"))
        XCTAssertTrue(written.contains("foreground = 0xffd8dee9"))
        XCTAssertTrue(written.contains("hover = 0x404c566a"))
    }

    func testApplyRefusesExistingThemeWithDifferentContent() throws {
        let root = try makeConfigRoot()
        try writeTheme(name: "Sample", to: root)
        try write("Sample\n", to: root.appendingPathComponent("themes/current_theme"))
        try write("return {\n\tcustom = 0xff010203,\n}\n", to: root.appendingPathComponent("themes/Nord.lua"))

        XCTAssertThrowsError(try makeService(root).apply(nord)) { error in
            XCTAssertEqual(error as? BarThemeError, .targetThemeExists("Nord"))
        }
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("themes/Nord.lua"), encoding: .utf8),
            "return {\n\tcustom = 0xff010203,\n}\n"
        )
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("themes/current_theme"), encoding: .utf8),
            "Sample\n"
        )
    }

    func testApplyTwiceIsANoOp() throws {
        let root = try makeConfigRoot()
        try writeTheme(name: "Sample", to: root)
        try write("Sample\n", to: root.appendingPathComponent("themes/current_theme"))
        let service = makeService(root)

        _ = try service.apply(nord)
        let second = try service.apply(nord)

        XCTAssertEqual(second, BarThemeApplyResult(themeName: "Nord", wroteThemeFile: false, wrotePointer: false))
    }

    func testRestorePutsPointerBackOnly() throws {
        let root = try makeConfigRoot()
        try writeTheme(name: "Sample", to: root)
        try write("Sample\n", to: root.appendingPathComponent("themes/current_theme"))
        let service = makeService(root)

        _ = try service.apply(nord)
        XCTAssertEqual(service.previousThemeName(), "Sample")

        let restored = try service.restorePreviousTheme()

        XCTAssertEqual(restored, "Sample")
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("themes/current_theme"), encoding: .utf8),
            "Sample\n"
        )
        XCTAssertNil(service.previousThemeName())
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("themes/Nord.lua").path))
    }

    func testUnknownKeysAreMappedByLuminance() throws {
        let root = try makeConfigRoot()
        try write(
            """
            return {
            \tquux = 0xff101010,
            \tcorge = 0xff808080,
            \tgrault = 0xfff0f0f0,
            }
            """,
            to: root.appendingPathComponent("themes/Sample.lua")
        )
        try write("Sample\n", to: root.appendingPathComponent("themes/current_theme"))

        try makeService(root).apply(nord)

        let written = try String(contentsOf: root.appendingPathComponent("themes/Nord.lua"), encoding: .utf8)
        XCTAssertTrue(written.contains("quux = 0xff2e3440"))
        XCTAssertTrue(written.contains("corge = 0xff4c566a"))
        XCTAssertTrue(written.contains("grault = 0xffd8dee9"))
    }

    func testNonHexValuesAndStructurePassThrough() throws {
        let root = try makeConfigRoot()
        let source = """
        return {
        \t-- keep this comment
        \tspecial = 42,
        \tbackground = 0xff101010,
        \tbar = {
        \t\tbg = 0x00000000,
        \t},
        \thandler = function(color)
        \t\treturn color
        \tend,
        }
        """
        try write(source, to: root.appendingPathComponent("themes/Sample.lua"))
        try write("Sample\n", to: root.appendingPathComponent("themes/current_theme"))

        try makeService(root).apply(nord)

        let written = try String(contentsOf: root.appendingPathComponent("themes/Nord.lua"), encoding: .utf8)
        XCTAssertTrue(written.contains("-- keep this comment"))
        XCTAssertTrue(written.contains("special = 42,"))
        XCTAssertTrue(written.contains("bg = 0x00000000,"))
        XCTAssertTrue(written.contains("handler = function(color)"))
        XCTAssertTrue(written.contains("background = 0xff2e3440"))
    }

    func testPaletteCatalogHasAtLeast24Palettes() {
        XCTAssertGreaterThanOrEqual(BarPalette.all.count, 24)
    }

    func testPaletteMetadataIsCompleteAndLicensed() {
        let allowedLicences: Set<String> = [
            "MIT", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause",
            "ISC", "CC0-1.0", "Unlicense"
        ]
        let identifiers = Set(BarPalette.all.map(\.id))

        XCTAssertEqual(identifiers.count, BarPalette.all.count)
        for palette in BarPalette.all {
            XCTAssertFalse(palette.sourceURL.isEmpty, palette.id)
            XCTAssertTrue(palette.sourceURL.hasPrefix("https://"), palette.id)
            XCTAssertTrue(allowedLicences.contains(palette.licence), "\(palette.id): \(palette.licence)")
            XCTAssertFalse(palette.swatches.isEmpty, palette.id)

            for role in BarPalette.Role.allCases {
                let hex = palette.hex(for: role)
                XCTAssertEqual(hex.count, 6, "\(palette.id).\(role)")
                XCTAssertTrue(hex.allSatisfy(\.isHexDigit), "\(palette.id).\(role)")
            }
        }
    }

    func testHueNamedKeysUseMatchingSwatches() throws {
        let written = try renderedTheme(
            """
            return {
            \tred = 0xff101010,
            \tgreen = 0xff101010,
            \tblue = 0xff101010,
            }
            """
        )

        XCTAssertTrue(written.contains("red = 0xffbf616a"))
        XCTAssertTrue(written.contains("green = 0xffa3be8c"))
        XCTAssertTrue(written.contains("blue = 0xff5e81ac"))
    }

    func testHueNamedKeysDoNotCollide() throws {
        let written = try renderedTheme(
            """
            return {
            \tred = 0xff101010,
            \tblue = 0xff101010,
            }
            """
        )

        XCTAssertTrue(written.contains("red = 0xffbf616a"))
        XCTAssertTrue(written.contains("blue = 0xff5e81ac"))
        XCTAssertNotEqual(
            BarThemeService.hexEntries(in: written).map(\.value),
            ["0xffbf616a", "0xffbf616a"]
        )
    }

    func testCompoundHueKeyUsesMatchingSwatch() throws {
        let written = try renderedTheme(
            """
            return {
            \tbattery_red = 0xff101010,
            }
            """
        )

        XCTAssertTrue(written.contains("battery_red = 0xffbf616a"))
    }

    func testSemanticKeyWinsOverHueName() throws {
        let written = try renderedTheme(
            """
            return {
            \taccent_red = 0xff101010,
            \tbackground_blue = 0xff101010,
            }
            """
        )

        XCTAssertTrue(written.contains("accent_red = 0xff88c0d0"))
        XCTAssertTrue(written.contains("background_blue = 0xff2e3440"))
    }

    func testAchromaticKeysUseLuminanceRoles() throws {
        let written = try renderedTheme(
            """
            return {
            \tgrey = 0xff808080,
            \tblack = 0xff101010,
            \twhite = 0xfff0f0f0,
            }
            """
        )

        XCTAssertTrue(written.contains("grey = 0xff4c566a"))
        XCTAssertTrue(written.contains("black = 0xff2e3440"))
        XCTAssertTrue(written.contains("white = 0xffd8dee9"))
    }

    func testMissingSwatchFallsBackToLuminance() throws {
        let palette = testPalette(swatches: ["#5e81ac"])
        let written = try renderedTheme(
            """
            return {
            \tred = 0xff101010,
            }
            """,
            palette: palette
        )

        XCTAssertTrue(written.contains("red = 0xff123456"))
    }

    func testHueMappingKeepsAlphaAndKeyOrder() throws {
        let written = try renderedTheme(
            """
            return {
            \tred = 0x40101010,
            \tblue = 0xff101010,
            \tcustom = 0xff808080,
            }
            """
        )

        XCTAssertTrue(written.contains("red = 0x40bf616a"))
        XCTAssertEqual(
            BarThemeService.hexEntries(in: written).map(\.key),
            ["red", "blue", "custom"]
        )
    }

    func testDisplayRoleOrderIsFixed() {
        XCTAssertEqual(
            BarPalette.displayRoleOrder,
            [.background, .foreground, .accent, .accentSecondary, .muted, .border]
        )
    }

    func testContrastFallbackUsesThePaletteOwnColours() {
        XCTAssertEqual(
            BarPalette.contrastRatio(between: "#000000", and: "#ffffff"),
            21,
            accuracy: 0.01
        )
        XCTAssertEqual(
            BarPalette.contrastRatio(between: "#777777", and: "#7a7a7a"),
            1,
            accuracy: 0.05
        )

        XCTAssertFalse(nord.foregroundNeedsContrastFallback)
        XCTAssertFalse(
            testPalette(swatches: ["#000000"]).foregroundNeedsContrastFallback
        )
        XCTAssertTrue(
            testPalette(
                swatches: ["#000000"],
                background: "#777777",
                foreground: "#7a7a7a"
            )
            .foregroundNeedsContrastFallback
        )
    }

    func testEveryPaletteSwatchIsValidHex() {
        for palette in BarPalette.all {
            XCTAssertFalse(palette.swatches.isEmpty, palette.id)
            for swatch in palette.swatches {
                XCTAssertTrue(swatch.hasPrefix("#"), "\(palette.id): \(swatch)")
                XCTAssertEqual(swatch.count, 7, "\(palette.id): \(swatch)")
                XCTAssertTrue(
                    swatch.dropFirst().allSatisfy(\.isHexDigit),
                    "\(palette.id): \(swatch)"
                )
            }
        }
    }

    // MARK: - Helpers

    private var nord: BarPalette {
        BarPalette.all.first { $0.id == "nord" }!
    }

    private func testPalette(
        swatches: [String],
        background: String = "#000000",
        foreground: String = "#ffffff"
    ) -> BarPalette {
        BarPalette(
            id: "test-palette",
            displayName: "Test Palette",
            family: "Test",
            isDark: true,
            background: background,
            foreground: foreground,
            accent: "#ff0000",
            accentSecondary: "#00ff00",
            muted: "#123456",
            border: "#654321",
            swatches: swatches,
            sourceURL: "https://example.com/palette",
            licence: "MIT"
        )
    }

    private func renderedTheme(_ source: String, palette: BarPalette? = nil) throws -> String {
        let palette = palette ?? nord
        let root = try makeConfigRoot()
        try write(source, to: root.appendingPathComponent("themes/Sample.lua"))
        try write("Sample\n", to: root.appendingPathComponent("themes/current_theme"))
        try makeService(root).apply(palette)
        return try String(
            contentsOf: root.appendingPathComponent("themes/\(palette.displayName).lua"),
            encoding: .utf8
        )
    }

    private func makeService(_ root: URL) -> BarThemeService {
        BarThemeService(configRoot: root, defaults: defaults)
    }

    private func writeTheme(name: String, to root: URL) throws {
        try write(
            """
            return {
            \tblack = 0xff1a1b26,
            \twhite = 0xffc0caf5,
            \tred = 0xfff7768e,
            \tgreen = 0xff9ece6a,
            \tblue = 0xff7aa2f7,
            \tgrey = 0xff565f89,
            \ttransparent = 0x00000000,
            \thover = 0x40FFFFFF,
            \tnotifications = 0xffc82d3b,
            \tbar = {
            \t\tbg = 0x00000000,
            \t\tborder = 0x00000000,
            \t},
            \twith_alpha = function(color, alpha)
            \t\treturn (color & 0x00ffffff) | (alpha << 24)
            \tend,
            }
            """,
            to: root.appendingPathComponent("themes/\(name).lua")
        )
    }

    private func makeConfigRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SketchyBarStudioTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
