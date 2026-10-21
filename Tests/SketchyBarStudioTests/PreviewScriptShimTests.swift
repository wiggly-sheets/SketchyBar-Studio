import CSketchyBar
import Foundation
@testable import SketchyBarStudio
import XCTest

/// The tests of the shim of the scripts of the items.
///
/// The shim is the contract between the scripts of the items and the
/// preview: it takes the `--set` calls the scripts make and writes them
/// into a sink file, so a script of the preview never reaches the live bar
/// of the user.
final class PreviewScriptShimTests: XCTestCase {
    // MARK: - The shim

    /// A `--set` call lands in the sink as an alias and a property.
    func testTheShimWritesTheSetCallIntoTheSink() throws {
        let installation = try PreviewScriptShim.Installation()
        defer { installation.remove() }

        let result = try runShim(installation, arguments: ["--set", "clock", "label=12:00"])

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.error, "")
        XCTAssertEqual(installation.assignments(),
                       [PreviewScriptShim.Assignment(alias: "clock", key: "label", value: "12:00")])
    }

    /// The marker of a message is skipped before the alias is read, so the
    /// form `-m --set` reaches the same path as the plain form.
    func testTheShimAcceptsTheMessageMarker() throws {
        let installation = try PreviewScriptShim.Installation()
        defer { installation.remove() }

        let result = try runShim(installation, arguments: ["-m", "--set", "clock", "label=12:00"])

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(installation.assignments(),
                       [PreviewScriptShim.Assignment(alias: "clock", key: "label", value: "12:00")])
    }

    /// The long form of the marker of a message reaches the same path.
    func testTheShimAcceptsTheLongMessageMarker() throws {
        let installation = try PreviewScriptShim.Installation()
        defer { installation.remove() }

        let result = try runShim(installation, arguments: ["--message", "--set", "clock", "label=12:00"])

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(installation.assignments(),
                       [PreviewScriptShim.Assignment(alias: "clock", key: "label", value: "12:00")])
    }

    /// Several properties of one call all land in the sink.
    func testTheShimWritesEveryPropertyOfTheCall() throws {
        let installation = try PreviewScriptShim.Installation()
        defer { installation.remove() }

        _ = try runShim(installation, arguments: ["--set", "clock", "label=12:00", "icon=calendar"])

        XCTAssertEqual(installation.assignments(),
                       [PreviewScriptShim.Assignment(alias: "clock", key: "label", value: "12:00"),
                        PreviewScriptShim.Assignment(alias: "clock", key: "icon", value: "calendar")])
    }

    /// A value that holds a space survives: the transport is NUL separated
    /// and not space separated (`src/misc/helpers.h:247-263`).
    func testTheShimKeepsAValueWithASpace() throws {
        let installation = try PreviewScriptShim.Installation()
        defer { installation.remove() }

        _ = try runShim(installation, arguments: ["--set", "clock", "label=Hello World"])

        XCTAssertEqual(installation.assignments(),
                       [PreviewScriptShim.Assignment(alias: "clock", key: "label", value: "Hello World")])
    }

    /// A value that holds an equal sign survives: the pair is split at the
    /// first equal sign only.
    func testTheShimKeepsAValueWithAnEqualSign() throws {
        let installation = try PreviewScriptShim.Installation()
        defer { installation.remove() }

        _ = try runShim(installation, arguments: ["--set", "clock", "label=a=b"])

        XCTAssertEqual(installation.assignments(),
                       [PreviewScriptShim.Assignment(alias: "clock", key: "label", value: "a=b")])
    }

    /// A command the shim does not handle is reported and never sent on.
    func testTheShimRefusesACommandItDoesNotHandle() throws {
        let installation = try PreviewScriptShim.Installation()
        defer { installation.remove() }

        let result = try runShim(installation, arguments: ["--query", "bar"])

        XCTAssertEqual(result.status, 64)
        XCTAssertEqual(result.error, "sketchybar: unsupported preview command: --query bar\n")
        XCTAssertEqual(installation.assignments(), [])
    }

    /// The shim never runs the real binary: the call of the script reaches
    /// the shim, and the binary that stands behind it is never run.
    func testTheShimNeverRunsTheRealBinary() throws {
        let installation = try PreviewScriptShim.Installation()
        defer { installation.remove() }

        // A binary that leaves a mark when it runs. It stands behind the
        // shim on the PATH, so the shim is found first.
        let marker = installation.directory.appendingPathComponent("the-real-binary-ran")
        let fakeDirectory = installation.directory.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeDirectory, withIntermediateDirectories: true)
        let fake = fakeDirectory.appendingPathComponent(PreviewScriptShim.executableName)
        try "#!/bin/sh\ntouch \(marker.path)\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let result = try runThroughPath(installation,
                                        command: "sketchybar --set clock label=12:00",
                                        path: [installation.directory.path,
                                               fakeDirectory.path,
                                               "/bin",
                                               "/usr/bin"])

        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "the shim must never run the binary behind it")
        XCTAssertEqual(installation.assignments(),
                       [PreviewScriptShim.Assignment(alias: "clock", key: "label", value: "12:00")])
    }

    /// The shim and its sink live in a directory of their own, and the
    /// directory is gone when the run is done.
    func testTheShimAndItsSinkAreRemovedWithTheDirectory() throws {
        let installation = try PreviewScriptShim.Installation()
        let directory = installation.directory

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(PreviewScriptShim.executableName).path))

        _ = try runShim(installation, arguments: ["--set", "clock", "label=12:00"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: installation.sinkURL.path))

        installation.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: - The runner

    /// The script of an item sets the label of the item in the preview.
    func testTheScriptOfAnItemSetsItsLabelInThePreview() throws {
        let handle = try XCTUnwrap(SketchyBarPreviewC.create())
        defer { SketchyBarPreviewC.destroy(handle) }
        SketchyBarPreviewC.setDisplay(handle, widthPoints: 480, heightPoints: 25)
        SketchyBarPreviewC.addItem(handle, alias: "clock", position: "left")
        SketchyBarPreviewC.setItem(handle, alias: "clock", key: "label", value: "before")

        let script = "sketchybar --set clock label=\"12:00\""
        SketchyBarPreviewC.setItem(handle, alias: "clock", key: "script", value: script)

        let runner = PreviewScriptRunner()
        let outcome = runner.values(for: [PreviewScriptRunner.Script(alias: "clock", script: script)],
                                    in: handle)

        XCTAssertEqual(outcome.assignments,
                       [PreviewScriptShim.Assignment(alias: "clock", key: "label", value: "12:00")])
        XCTAssertEqual(outcome.warnings, [])

        // The script itself does not change the preview: the assignments it
        // made are what the preview applies.
        let before = try XCTUnwrap(BarPreviewTestAccessors.itemSerialization(handle, alias: "clock"))
        XCTAssertTrue(before.contains("\"value\": \"before\""), before)

        for assignment in outcome.assignments {
            SketchyBarPreviewC.setItem(handle, alias: "clock",
                                       key: assignment.key,
                                       value: assignment.value)
        }

        let serialization = try XCTUnwrap(BarPreviewTestAccessors.itemSerialization(handle, alias: "clock"))
        XCTAssertTrue(serialization.contains("\"value\": \"12:00\""), serialization)
    }

    /// The form with the marker of a message sets the label as well.
    func testTheScriptWithTheMessageMarkerSetsItsLabelInThePreview() throws {
        let handle = try XCTUnwrap(SketchyBarPreviewC.create())
        defer { SketchyBarPreviewC.destroy(handle) }
        SketchyBarPreviewC.setDisplay(handle, widthPoints: 480, heightPoints: 25)
        SketchyBarPreviewC.addItem(handle, alias: "clock", position: "left")

        let script = "sketchybar -m --set clock label=\"12:00\""
        SketchyBarPreviewC.setItem(handle, alias: "clock", key: "script", value: script)

        let runner = PreviewScriptRunner()
        let outcome = runner.values(for: [PreviewScriptRunner.Script(alias: "clock", script: script)],
                                    in: handle)

        XCTAssertEqual(outcome.assignments,
                       [PreviewScriptShim.Assignment(alias: "clock", key: "label", value: "12:00")])
        XCTAssertEqual(outcome.warnings, [])
    }

    /// A value with a space survives the whole way: the script, the sink and
    /// the parser of the preview.
    func testAValueWithASpaceReachesThePreview() throws {
        let handle = try XCTUnwrap(SketchyBarPreviewC.create())
        defer { SketchyBarPreviewC.destroy(handle) }
        SketchyBarPreviewC.setDisplay(handle, widthPoints: 480, heightPoints: 25)
        SketchyBarPreviewC.addItem(handle, alias: "clock", position: "left")

        let script = "sketchybar --set clock label=\"Hello World\""
        SketchyBarPreviewC.setItem(handle, alias: "clock", key: "script", value: script)

        let runner = PreviewScriptRunner()
        let outcome = runner.values(for: [PreviewScriptRunner.Script(alias: "clock", script: script)],
                                    in: handle)

        XCTAssertEqual(outcome.assignments,
                       [PreviewScriptShim.Assignment(alias: "clock", key: "label", value: "Hello World")])

        for assignment in outcome.assignments {
            SketchyBarPreviewC.setItem(handle, alias: "clock",
                                       key: assignment.key,
                                       value: assignment.value)
        }

        let serialization = try XCTUnwrap(BarPreviewTestAccessors.itemSerialization(handle, alias: "clock"))
        XCTAssertTrue(serialization.contains("\"value\": \"Hello World\""), serialization)
    }

    /// The child of a script gets the name of the item and the sender.
    func testTheChildOfAScriptGetsTheNameOfTheItemAndTheSender() throws {
        let handle = try XCTUnwrap(SketchyBarPreviewC.create())
        defer { SketchyBarPreviewC.destroy(handle) }
        SketchyBarPreviewC.setDisplay(handle, widthPoints: 480, heightPoints: 25)
        SketchyBarPreviewC.addItem(handle, alias: "clock", position: "left")

        let script = "sketchybar --set \"$NAME\" label=\"$SENDER\""
        SketchyBarPreviewC.setItem(handle, alias: "clock", key: "script", value: script)

        let runner = PreviewScriptRunner()
        let outcome = runner.values(for: [PreviewScriptRunner.Script(alias: "clock", script: script)],
                                    in: handle)

        XCTAssertEqual(outcome.assignments,
                       [PreviewScriptShim.Assignment(alias: "clock", key: "label", value: "routine")])
    }

    /// A script that runs too long is stopped, and the preview says so.
    func testAScriptThatRunsTooLongIsStoppedAndReported() throws {
        let handle = try XCTUnwrap(SketchyBarPreviewC.create())
        defer { SketchyBarPreviewC.destroy(handle) }
        SketchyBarPreviewC.setDisplay(handle, widthPoints: 480, heightPoints: 25)
        SketchyBarPreviewC.addItem(handle, alias: "clock", position: "left")

        let script = "sleep 60"
        SketchyBarPreviewC.setItem(handle, alias: "clock", key: "script", value: script)

        let runner = PreviewScriptRunner()
        let started = Date()
        let outcome = runner.values(for: [PreviewScriptRunner.Script(alias: "clock", script: script)],
                                    in: handle)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 10, "the script must be stopped, not waited for")
        XCTAssertTrue(outcome.warnings.contains { $0.contains("did not finish") },
                      "\(outcome.warnings)")
    }

    /// A command the shim does not handle is a warning of the preview.
    func testAnUnsupportedCommandIsAWarningOfThePreview() throws {
        let handle = try XCTUnwrap(SketchyBarPreviewC.create())
        defer { SketchyBarPreviewC.destroy(handle) }
        SketchyBarPreviewC.setDisplay(handle, widthPoints: 480, heightPoints: 25)
        SketchyBarPreviewC.addItem(handle, alias: "clock", position: "left")

        let script = "sketchybar --query bar"
        SketchyBarPreviewC.setItem(handle, alias: "clock", key: "script", value: script)

        let runner = PreviewScriptRunner()
        let outcome = runner.values(for: [PreviewScriptRunner.Script(alias: "clock", script: script)],
                                    in: handle)

        XCTAssertTrue(outcome.warnings.contains { $0.contains("unsupported preview command") },
                      "\(outcome.warnings)")
        XCTAssertTrue(outcome.warnings.contains { $0.contains("failed with the code 64") },
                      "\(outcome.warnings)")
        XCTAssertEqual(outcome.assignments, [])
    }

    /// A script that calls the binary by its absolute path is not
    /// intercepted, and the preview warns about it.
    func testAScriptThatCallsTheBinaryByItsAbsolutePathIsAWarning() throws {
        let handle = try XCTUnwrap(SketchyBarPreviewC.create())
        defer { SketchyBarPreviewC.destroy(handle) }
        SketchyBarPreviewC.setDisplay(handle, widthPoints: 480, heightPoints: 25)
        SketchyBarPreviewC.addItem(handle, alias: "clock", position: "left")

        let script = "/opt/homebrew/bin/sketchybar --set clock label=12:00"
        SketchyBarPreviewC.setItem(handle, alias: "clock", key: "script", value: script)

        let runner = PreviewScriptRunner()
        let outcome = runner.values(for: [PreviewScriptRunner.Script(alias: "clock", script: script)],
                                    in: handle)

        XCTAssertTrue(outcome.warnings.contains { $0.contains("absolute path") }, "\(outcome.warnings)")
    }

    // MARK: - The helpers

    /// Runs the shim and reads its standard error.
    @discardableResult
    private func runShim(_ installation: PreviewScriptShim.Installation,
                         arguments: [String]) throws -> (status: Int32, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [installation.directory
            .appendingPathComponent(PreviewScriptShim.executableName).path] + arguments

        var environment = ProcessInfo.processInfo.environment
        environment[PreviewScriptShim.sinkEnvironmentKey] = installation.sinkURL.path
        process.environment = environment

        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (process.terminationStatus, String(data: errorData, encoding: .utf8) ?? "")
    }

    /// Runs a command with a PATH of its own, so the shim is found first.
    @discardableResult
    private func runThroughPath(_ installation: PreviewScriptShim.Installation,
                                command: String,
                                path: [String]) throws -> (status: Int32, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sh", "-c", command]

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path.joined(separator: ":")
        environment[PreviewScriptShim.sinkEnvironmentKey] = installation.sinkURL.path
        process.environment = environment

        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (process.terminationStatus, String(data: errorData, encoding: .utf8) ?? "")
    }
}
