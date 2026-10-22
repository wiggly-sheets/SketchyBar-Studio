import Foundation
@testable import SketchyBarStudio
import XCTest

final class ShellDiagnosticServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellDiagnosticServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testDetectsDuplicateAliasesInSameFile() throws {
        let file = tempDir.appendingPathComponent("sketchybarrc")
        let contents = """
        sketchybar --add item clock right
        sketchybar --add item clock left
        """
        try contents.write(to: file, atomically: true, encoding: .utf8)

        let service = ShellDiagnosticService()
        let diagnostics = service.diagnose(file: file, root: tempDir)

        let duplicates = diagnostics.filter { $0.kind == .duplicateAlias }
        XCTAssertEqual(duplicates.count, 1)
        XCTAssertEqual(duplicates.first?.keyPath, "clock")
        XCTAssertEqual(duplicates.first?.severity, .error)
    }

    func testDetectsMissingLabelWhenItemIsSetWithoutAdd() throws {
        let file = tempDir.appendingPathComponent("sketchybarrc")
        let contents = """
        sketchybar --set clock label="10:00"
        """
        try contents.write(to: file, atomically: true, encoding: .utf8)

        let service = ShellDiagnosticService()
        let diagnostics = service.diagnose(file: file, root: tempDir)

        let missing = diagnostics.filter { $0.kind == .missingLabel }
        XCTAssertTrue(missing.contains { $0.keyPath == "clock" })
    }

    func testDetectsItemAddedWithoutPosition() throws {
        let file = tempDir.appendingPathComponent("sketchybarrc")
        let contents = """
        sketchybar --add item clock
        """
        try contents.write(to: file, atomically: true, encoding: .utf8)

        let service = ShellDiagnosticService()
        let diagnostics = service.diagnose(file: file, root: tempDir)

        let missing = diagnostics.filter { $0.kind == .missingLabel }
        XCTAssertTrue(missing.contains { $0.keyPath == "clock" })
    }

    func testDetectsMissingScriptFile() throws {
        let file = tempDir.appendingPathComponent("sketchybarrc")
        let contents = """
        sketchybar --add item clock right
        sketchybar --set clock script="nonexistent.sh"
        """
        try contents.write(to: file, atomically: true, encoding: .utf8)

        let service = ShellDiagnosticService()
        let diagnostics = service.diagnose(file: file, root: tempDir)

        let missingFile = diagnostics.filter { $0.kind == .missingFile }
        XCTAssertEqual(missingFile.count, 1)
        XCTAssertEqual(missingFile.first?.keyPath, "script")
    }

    func testIgnoresScriptWithDynamicPath() throws {
        let file = tempDir.appendingPathComponent("sketchybarrc")
        let contents = """
        sketchybar --add item clock right
        sketchybar --set clock script="$PLUGIN_DIR/clock.sh"
        """
        try contents.write(to: file, atomically: true, encoding: .utf8)

        let service = ShellDiagnosticService()
        let diagnostics = service.diagnose(file: file, root: tempDir)

        let missingFile = diagnostics.filter { $0.kind == .missingFile }
        XCTAssertEqual(missingFile.count, 0)
    }

    func testDetectsBrokenLoaderLine() throws {
        let file = tempDir.appendingPathComponent("sketchybarrc")
        let contents = """
        source nonexistent_items.sh
        """
        try contents.write(to: file, atomically: true, encoding: .utf8)

        let service = ShellDiagnosticService()
        let diagnostics = service.diagnose(file: file, root: tempDir)

        let brokenLoaders = diagnostics.filter { $0.kind == .brokenLoader }
        XCTAssertEqual(brokenLoaders.count, 1)
        XCTAssertEqual(brokenLoaders.first?.keyPath, "nonexistent_items.sh")
    }

    func testDetectsNoSketchyBarCommand() throws {
        let file = tempDir.appendingPathComponent("helper.sh")
        let contents = """
        echo "Just a helper script"
        """
        try contents.write(to: file, atomically: true, encoding: .utf8)

        let service = ShellDiagnosticService()
        let diagnostics = service.diagnose(file: file, root: tempDir)

        let missing = diagnostics.filter { $0.kind == .missingLabel }
        XCTAssertTrue(missing.contains { $0.title == "No SketchyBar command" })
    }

    func testCrossFileDuplicateAliasWithConfigValidator() throws {
        let file1 = tempDir.appendingPathComponent("sketchybarrc")
        let contents1 = """
        sketchybar --add item battery right
        """
        try contents1.write(to: file1, atomically: true, encoding: .utf8)

        let file2 = tempDir.appendingPathComponent("items/battery.sh")
        let contents2 = """
        sketchybar --add item battery left
        """
        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent("items"), withIntermediateDirectories: true)
        try contents2.write(to: file2, atomically: true, encoding: .utf8)

        let validator = ConfigValidator()
        let diagnostics = validator.validate(rootURL: tempDir)

        let duplicates = diagnostics.filter { $0.kind == .duplicateAlias && $0.keyPath == "battery" }
        XCTAssertEqual(duplicates.count, 1)
    }

    func testItemClonerWorksWithShellConfig() throws {
        let contents = """
        sketchybar --add item clock right
        sketchybar --set clock label="10:00"
        """

        let cloner = ItemCloner()
        let alias = cloner.sourceAlias(in: contents)
        XCTAssertEqual(alias, "clock")

        let cloned = cloner.clonedContents(of: contents, newAlias: "clock_2")
        XCTAssertTrue(cloned.contains("--add item clock_2 right"))
    }

    func testDuplicateFinderFindsShellDuplicates() throws {
        let itemsDir = tempDir.appendingPathComponent("items")
        try FileManager.default.createDirectory(at: itemsDir, withIntermediateDirectories: true)

        let file1 = itemsDir.appendingPathComponent("item1.sh")
        let contents1 = """
        sketchybar --add item one right
        sketchybar --set one icon.font.size=12 label.color=0xffffffff
        """
        try contents1.write(to: file1, atomically: true, encoding: .utf8)

        let file2 = itemsDir.appendingPathComponent("item2.sh")
        let contents2 = """
        sketchybar --add item two right
        sketchybar --set two icon.font.size=12 label.color=0xffffffff
        """
        try contents2.write(to: file2, atomically: true, encoding: .utf8)

        let finder = DuplicateFinder()
        let pairs = finder.findDuplicates(in: tempDir, threshold: 0.8)

        XCTAssertFalse(pairs.isEmpty)
    }
}