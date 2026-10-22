import CSketchyBar
import Foundation
@testable import SketchyBarStudio
import XCTest

/// The tests of the isolation of the preview.
///
/// The scripts of the items run inside the preview, and they must never
/// change the live bar of the user. The shim stands in for the binary of
/// the daemon, the `PATH` of the child does not hold the directory of the
/// real binary, and the sink of the preview lives in a directory of its own.
final class PreviewIsolationTests: XCTestCase {
    /// The value the scripts of the preview would set on the live bar.
    private let sentinel = "SKETCHYBAR_STUDIO_PREVIEW_SENTINEL"

    // MARK: - The PATH of the child

    /// The child of a script gets the directory of the shim first on its
    /// PATH, and the directory of the real binary is not on it at all.
    func testTheChildOfAScriptHasNoDirectoryWithTheRealBinary() throws {
        let installation = try PreviewScriptShim.Installation()
        defer { installation.remove() }

        SketchyBarPreviewC.setScriptEnvironment(shimDirectory: installation.directory.path,
                                                sinkPath: installation.sinkURL.path,
                                                logDirectory: installation.logDirectory.path)

        let entries = pathEntries(in: BarPreviewTestAccessors.childEnvironment())

        XCTAssertEqual(entries.first, installation.directory.path,
                       "the shim has to come first on the PATH of the child")
        XCTAssertTrue(entries.contains("/bin"), "the child needs a shell: \(entries)")
        XCTAssertTrue(entries.contains("/usr/bin"), "the child needs a shell: \(entries)")

        for directory in directoriesWithRealBinary() {
            XCTAssertFalse(entries.contains(directory),
                           "the child must not have \(directory) on its PATH: \(entries)")
        }
    }

    /// The child of a script does not get a directory that holds a file
    /// called `sketchybar` on its PATH.
    ///
    /// The test builds that directory itself, so the assertion always means
    /// something: the directories of the PATH of the test process may hold
    /// no binary at all, and then the loop above proves nothing.
    func testTheChildOfAScriptHasNoDirectoryWithABinaryOnItsPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewIsolation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let binary = directory.appendingPathComponent(PreviewScriptShim.executableName)
        try "#!/bin/sh\nexit 0\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        // The directory is on the PATH of the app while the environment of
        // the child is built.
        let original = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", "\(directory.path):\(original)", 1)
        defer { setenv("PATH", original, 1) }

        let installation = try PreviewScriptShim.Installation()
        defer { installation.remove() }

        SketchyBarPreviewC.setScriptEnvironment(shimDirectory: installation.directory.path,
                                                sinkPath: installation.sinkURL.path,
                                                logDirectory: installation.logDirectory.path)

        let entries = pathEntries(in: BarPreviewTestAccessors.childEnvironment())

        XCTAssertFalse(entries.contains(directory.path),
                       "the child must not have the directory of a sketchybar binary on its PATH: \(entries)")
        XCTAssertEqual(entries.first, installation.directory.path,
                       "the shim has to come first on the PATH of the child")
    }

    // MARK: - The live bar

    /// A script of the preview that resolves `sketchybar` through the PATH
    /// cannot change the live bar.
    ///
    /// The test needs a running daemon: it is skipped when the daemon does
    /// not answer, and it never fails the build because of that.
    func testTheScriptsOfThePreviewCannotChangeTheLiveBar() throws {
        guard let before = queryLiveBar() else {
            throw XCTSkip("the daemon of SketchyBar is not running")
        }

        let aliases = itemNames(in: before)
        XCTAssertFalse(aliases.isEmpty, "the live bar must hold items for the test to mean something")

        // A preview whose scripts would change every item of the live bar.
        let handle = try XCTUnwrap(SketchyBarPreviewC.create())
        defer { SketchyBarPreviewC.destroy(handle) }
        SketchyBarPreviewC.setDisplay(handle, widthPoints: 480, heightPoints: 25)

        var scripts: [PreviewScriptRunner.Script] = []
        for alias in aliases {
            SketchyBarPreviewC.addItem(handle, alias: alias, position: "left")
            let script = "sketchybar --set \"\(alias)\" label=\"\(sentinel)\""
            SketchyBarPreviewC.setItem(handle, alias: alias, key: "script", value: script)
            // The daemon runs the script of an item from its clock, so the
            // item needs an update frequency (src/bar_item.c:127).
            SketchyBarPreviewC.setItem(handle, alias: alias, key: "update_freq", value: "1")
            scripts.append(PreviewScriptRunner.Script(alias: alias, script: script))
        }

        let runner = PreviewScriptRunner()
        let outcome = runner.values(for: scripts, in: handle)

        // The scripts ran, and the shim caught every call of them.
        XCTAssertEqual(outcome.assignments.count, aliases.count)
        XCTAssertTrue(outcome.assignments.allSatisfy { $0.value == sentinel })

        // The live bar is untouched.
        let after = try XCTUnwrap(queryLiveBar())
        XCTAssertFalse(after.contains(sentinel),
                       "the live bar must not show the value of the preview")
    }

    // MARK: - The soak

    /// The live-value loop does not leak file descriptors and does not grow
    /// the resident memory of the process.
    ///
    /// The loop is the one of the preview: create a preview, run the item
    /// scripts, read the sink, re-render and destroy. Every cycle runs the
    /// scripts of the item in a child process, so the loop covers the
    /// children of the scripts, the log files and the sink as well.
    ///
    /// The cycle runs inside an autorelease pool. The files of the shim are
    /// written and removed with Foundation, and Foundation leaves its own
    /// objects in the pool of the run loop. Without the pool, the resident
    /// size of the process grows by about 3.5 kilobytes per cycle, which is
    /// the pool and not a leak of the preview.
    ///
    /// The resident size of a process also grows while the heap of the core
    /// finds its working size, and that growth is not a leak: it is bounded
    /// and it stops. The warm-up pays it, and the measured cycles then show
    /// the steady state.
    ///
    /// The tolerance is 65,536 bytes, the same tolerance the soak of stage 2
    /// uses.
    ///
    /// The measured numbers on this machine, after the warm-up of fifty
    /// cycles: the descriptor count stays at 11, and the resident size does
    /// not grow over the two hundred cycles: 28,491,776 bytes before the
    /// cycles and 28,491,776 bytes after them.
    func testTheSoakOfTheLiveValueLoopKeepsTheProcessSmall() throws {
        for _ in 0..<50 { runLiveValueCycle() }

        let descriptorsBefore = openFileDescriptorCount()
        let residentBefore = residentSize()

        for _ in 0..<200 { runLiveValueCycle() }

        let descriptorsAfter = openFileDescriptorCount()
        let residentAfter = residentSize()

        XCTAssertEqual(descriptorsBefore, descriptorsAfter,
                       "a live-value cycle must not open a file descriptor")
        XCTAssertLessThanOrEqual(Int64(residentAfter) - Int64(residentBefore), 65_536,
                                 "the resident size must not grow over the cycles")
        print("soak: descriptors \(descriptorsBefore) -> \(descriptorsAfter), resident \(residentBefore) -> \(residentAfter) bytes")
    }

    /// One cycle of the live-value loop.
    ///
    /// The cycle is the path of the app: the render route runs the scripts
    /// of the items of the preview, the timer route runs the scripts by
    /// their text, and the tick of the timer builds a tree of its own and
    /// runs the routine of the items. Every route runs the scripts in a
    /// child process and builds a tree of the vendored core, so the loop
    /// covers the children of the scripts, the log files, the sink and the
    /// tree of the preview.
    private func runLiveValueCycle() {
        autoreleasepool {
            let script = "sketchybar --set clock label=12:00"
            let scripts = [PreviewScriptRunner.Script(alias: "clock", script: script)]
            let plan = BarRenderPlan(
                defaults: [],
                bar: [],
                items: [BarRenderItemModel(alias: "clock",
                                           properties: [BarRenderProperty(key: "script", value: script),
                                                       BarRenderProperty(key: "update_freq", value: "1")])],
                warnings: []
            )

            guard let handle = SketchyBarPreviewC.create() else { return }

            SketchyBarPreviewC.setDisplay(handle, widthPoints: 480, heightPoints: 25)
            SketchyBarPreviewC.addItem(handle, alias: "clock", position: "left")
            SketchyBarPreviewC.setItem(handle, alias: "clock", key: "script", value: script)
            // The daemon runs the script of an item from its clock, so the
            // item asks for an update frequency (src/bar_item.c:127-133).
            SketchyBarPreviewC.setItem(handle, alias: "clock", key: "update_freq", value: "1")

            // A runner of its own for every cycle, so the scripts run again
            // and the loop covers the whole path.
            let runner = PreviewScriptRunner()
            runner.noteRequest(scripts: scripts)

            // The render route: the scripts of the items of the preview.
            let outcome = runner.values(for: scripts, in: handle)
            for assignment in outcome.assignments {
                SketchyBarPreviewC.setItem(handle, alias: "clock",
                                           key: assignment.key,
                                           value: assignment.value)
            }

            _ = SketchyBarPreviewC.render(handle)
            SketchyBarPreviewC.destroy(handle)

            // The timer route: the scripts by their text.
            _ = runner.runCurrentScripts()

            // The tick of the timer: a tree of its own and the routine of
            // the items, the way the daemon runs them.
            _ = runner.runItems(of: plan, widthPoints: 480, heightPoints: 25)
        }
    }

    // MARK: - The live bar of the machine

    /// The reply of `sketchybar --query bar`, or nil when the daemon of
    /// SketchyBar does not answer.
    private func queryLiveBar() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sketchybar", "--query", "bar"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.isEmpty ? nil : text
    }

    /// The names of the items of the live bar.
    ///
    /// The reply of the daemon holds the items in a list of names
    /// (`src/bar_manager.c:1121-1126`).
    private func itemNames(in reply: String) -> [String] {
        guard let start = reply.range(of: "\"items\": [") else { return [] }
        guard let end = reply.range(of: "]", range: start.upperBound..<reply.endIndex) else { return [] }

        return reply[start.upperBound..<end.lowerBound]
            .split(separator: ",")
            .compactMap { part in
                let name = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard name.hasPrefix("\""), name.hasSuffix("\"") else { return nil }
                return String(name.dropFirst().dropLast())
            }
    }

    // MARK: - The environment of the child

    /// The entries of the PATH of the child.
    private func pathEntries(in environment: String) -> [String] {
        guard let line = environment.split(separator: "\n").first(where: { $0.hasPrefix("PATH=") }) else {
            return []
        }
        return line.dropFirst("PATH=".count)
            .split(separator: ":")
            .map(String.init)
    }

    /// The directories of the PATH of the app that hold a sketchybar binary.
    private func directoriesWithRealBinary() -> [String] {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":").compactMap { entry in
            let url = URL(fileURLWithPath: String(entry))
                .appendingPathComponent(PreviewScriptShim.executableName)
            return FileManager.default.fileExists(atPath: url.path) ? String(entry) : nil
        }
    }

    // MARK: - The measurement of the process

    // The flavours of proc_pidinfo. The Darwin module of Swift does not
    // export the macros of <sys/proc_info.h>.
    private let procPidListFds: Int32 = 1
    private let procPidTaskInfo: Int32 = 4

    /// The number of open file descriptors of the process.
    private func openFileDescriptorCount() -> Int {
        let capacity = 1024
        let stride = MemoryLayout<proc_fdinfo>.stride
        let size = Int32(stride * capacity)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                      alignment: MemoryLayout<proc_fdinfo>.alignment)
        defer { buffer.deallocate() }

        let count = proc_pidinfo(getpid(), procPidListFds, 0, buffer, size)
        return Int(count) / stride
    }

    /// The resident size of the process, in bytes.
    private func residentSize() -> UInt64 {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.stride)
        let written = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(getpid(), procPidTaskInfo, 0, pointer, size)
        }
        return written == size ? info.pti_resident_size : 0
    }
}
