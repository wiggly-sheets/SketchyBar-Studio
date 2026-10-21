import Darwin
import Foundation
import XCTest
@testable import SketchyBarStudio

/// The tests of the headless preview core of stage 2.
///
/// They cover the item tree of the C API: the lifecycle of a preview, the
/// item properties, the snapshot of the default item, the environment of the
/// child of the script runner and the soak of a thousand cycles.
final class BarPreviewCoreTests: XCTestCase {
    // MARK: - The item tree

    /// The smoke test of the stage: a preview is created, one item is added
    /// with a fixed width, one property is set on it and the preview is
    /// destroyed. The property has to have reached the item.
    func testPreviewItemLifecycle() {
        let handle = SketchyBarPreviewC.create()
        XCTAssertNotNil(handle, "the core must hand out a preview handle")
        defer { SketchyBarPreviewC.destroy(handle) }

        XCTAssertEqual(SketchyBarPreviewC.setDisplay(handle, widthPoints: 480, heightPoints: 25), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.addItem(handle, alias: "apple", position: "left"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.setItem(handle, alias: "apple", key: "width", value: "120"), SketchyBarPreviewC.Code.ok)

        XCTAssertEqual(BarPreviewTestAccessors.itemWidth(handle, alias: "apple"), 120)
    }

    /// The alias of an item that does not exist is a failure, not a crash.
    func testPreviewRejectsAnUnknownAlias() {
        let handle = SketchyBarPreviewC.create()
        XCTAssertNotNil(handle)
        defer { SketchyBarPreviewC.destroy(handle) }

        XCTAssertEqual(SketchyBarPreviewC.setItem(handle, alias: "nope", key: "width", value: "10"),
                       SketchyBarPreviewC.Code.itemNotFound)
    }

    /// Two items may not share an alias: the alias addresses one item.
    func testPreviewRejectsADuplicateAlias() {
        let handle = SketchyBarPreviewC.create()
        XCTAssertNotNil(handle)
        defer { SketchyBarPreviewC.destroy(handle) }

        XCTAssertEqual(SketchyBarPreviewC.addItem(handle, alias: "apple", position: "left"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.addItem(handle, alias: "apple", position: "left"), SketchyBarPreviewC.Code.itemExists)
    }

    /// A property the vendored parser does not know is reported as a
    /// failure, and the message of the parser is kept.
    func testPreviewReportsARejectedProperty() {
        let handle = SketchyBarPreviewC.create()
        XCTAssertNotNil(handle)
        defer { SketchyBarPreviewC.destroy(handle) }

        XCTAssertEqual(SketchyBarPreviewC.addItem(handle, alias: "apple", position: "left"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.setItem(handle, alias: "apple", key: "not_a_property", value: "1"),
                       SketchyBarPreviewC.Code.propertyRejected)

        let messages = SketchyBarPreviewC.messages(handle)
        XCTAssertTrue(messages.contains("[!]"), "the message of the parser must be kept: \(messages)")
        XCTAssertTrue(messages.contains("not_a_property"), "the message must name the property: \(messages)")
    }

    /// A property of the bar goes through the bar domain of the vendored
    /// core.
    func testPreviewAppliesABarProperty() {
        let handle = SketchyBarPreviewC.create()
        XCTAssertNotNil(handle)
        defer { SketchyBarPreviewC.destroy(handle) }

        XCTAssertEqual(SketchyBarPreviewC.setBar(handle, key: "margin", value: "10"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.setBar(handle, key: "position", value: "bottom"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.setBar(handle, key: "clip", value: "0.5"),
                       SketchyBarPreviewC.Code.propertyRejected)
    }

    /// Only one preview exists at a time: the vendored core keeps its model
    /// in one global.
    func testPreviewAllowsOnlyOneHandle() {
        let handle = SketchyBarPreviewC.create()
        XCTAssertNotNil(handle)
        defer { SketchyBarPreviewC.destroy(handle) }

        XCTAssertNil(SketchyBarPreviewC.create(), "a second preview must not take over the model of the first one")
    }

    /// The menu bar of the virtual display is set after the display, and a
    /// negative height is refused.
    func testPreviewSetsTheMenuBar() {
        let handle = SketchyBarPreviewC.create()
        XCTAssertNotNil(handle)
        defer { SketchyBarPreviewC.destroy(handle) }

        XCTAssertEqual(SketchyBarPreviewC.setDisplay(handle, widthPoints: 480, heightPoints: 25), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.setMenuBar(handle, heightPoints: 24), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.setMenuBar(handle, heightPoints: 0), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.setMenuBar(handle, heightPoints: -1), SketchyBarPreviewC.Code.invalidArgument)
    }

    // MARK: - The defaults

    /// A default that is set before the item is created is inherited by the
    /// item. That is the snapshot of the daemon (src/bar_manager.c:463,
    /// src/bar_item.c:68, src/bar_item.c:883-933).
    func testDefaultSetBeforeTheItemIsInherited() {
        let handle = SketchyBarPreviewC.create()
        XCTAssertNotNil(handle)
        defer { SketchyBarPreviewC.destroy(handle) }

        XCTAssertEqual(SketchyBarPreviewC.setDefault(handle, key: "padding_left", value: "7"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.addItem(handle, alias: "apple", position: "left"), SketchyBarPreviewC.Code.ok)

        XCTAssertEqual(BarPreviewTestAccessors.itemPaddingLeft(handle, alias: "apple"), 7)
    }

    /// A default that is set after the item exists never reaches that item.
    func testDefaultSetAfterTheItemDoesNotReachIt() {
        let handle = SketchyBarPreviewC.create()
        XCTAssertNotNil(handle)
        defer { SketchyBarPreviewC.destroy(handle) }

        XCTAssertEqual(SketchyBarPreviewC.addItem(handle, alias: "apple", position: "left"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.setDefault(handle, key: "padding_left", value: "7"), SketchyBarPreviewC.Code.ok)

        XCTAssertEqual(BarPreviewTestAccessors.itemPaddingLeft(handle, alias: "apple"), 0)
    }

    /// The reset empties the default item again, like `--default reset` does.
    func testDefaultResetEmptiesTheDefaultItem() {
        let handle = SketchyBarPreviewC.create()
        XCTAssertNotNil(handle)
        defer { SketchyBarPreviewC.destroy(handle) }

        XCTAssertEqual(SketchyBarPreviewC.setDefault(handle, key: "padding_left", value: "7"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.setDefault(handle, key: "reset", value: ""), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.addItem(handle, alias: "apple", position: "left"), SketchyBarPreviewC.Code.ok)

        XCTAssertEqual(BarPreviewTestAccessors.itemPaddingLeft(handle, alias: "apple"), 0)
    }

    // MARK: - The child of the script runner

    /// The child of the script runner never gets BAR_NAME: the daemon sets
    /// it for its own children (src/sketchybar.c:208) and a script of the
    /// preview must never believe it talks to the real daemon.
    func testChildEnvironmentHasNoBarName() {
        setenv("BAR_NAME", "sketchybar", 1)
        defer { unsetenv("BAR_NAME") }

        let environment = BarPreviewTestAccessors.childEnvironment()
        XCTAssertFalse(environment.contains("BAR_NAME="), "the child must not get BAR_NAME: \(environment)")
        XCTAssertTrue(environment.contains("SKETCHYBAR_PREVIEW=1"), "the child must know it runs in a preview: \(environment)")
        XCTAssertTrue(environment.contains("PATH="), "the child must inherit the environment of the app: \(environment)")
    }

    /// The environment of the app itself is never changed by the script
    /// runner: the daemon sets the variables of the item in the parent
    /// (src/misc/helpers.h:442-446).
    func testTheEnvironmentOfTheAppIsUntouched() {
        setenv("BAR_NAME", "sketchybar", 1)
        defer { unsetenv("BAR_NAME") }

        _ = BarPreviewTestAccessors.childEnvironment()

        XCTAssertEqual(getenv("BAR_NAME").map { String(cString: $0) }, "sketchybar")
    }

    // MARK: - The soak

    /// Ten thousand create and destroy cycles leave the process with the
    /// same number of open file descriptors and the same resident memory.
    ///
    /// The resident size of a process grows while the heap of the core finds
    /// its working size, and that growth is not a leak: it is bounded and it
    /// stops. The warm-up of a thousand cycles pays it, and the measured
    /// ten thousand cycles then show the steady state.
    ///
    /// The tolerance is 65,536 bytes. The leak this catches is one item name
    /// per cycle: the name of an item is a malloc chunk of about 32 bytes, so
    /// a leak of one name per cycle is about 320,000 bytes over the ten
    /// thousand cycles, which is over the tolerance. Over a thousand cycles
    /// the same leak would be about 32,000 bytes, which is under the
    /// tolerance, so the soak has to run ten thousand cycles to catch it.
    ///
    /// The measured numbers on this machine, after the warm-up of a thousand
    /// cycles: the descriptor count stays at 88, and the resident size grows
    /// by 32,768 bytes over the ten thousand cycles. Over forty thousand
    /// cycles it grows by 0 bytes, so the growth is the heap of the process
    /// finding its working size and not a leak.
    func testSoakKeepsTheFileDescriptorCount() {
        // The warm-up pays the one-time allocations of the core, which are
        // not a leak.
        for _ in 0..<1000 { runPreviewCycle() }

        let descriptorsBefore = openFileDescriptorCount()
        let residentBefore = residentSize()

        for _ in 0..<10000 { runPreviewCycle() }

        let descriptorsAfter = openFileDescriptorCount()
        let residentAfter = residentSize()

        XCTAssertEqual(descriptorsBefore, descriptorsAfter, "a preview cycle must not open a file descriptor")
        XCTAssertLessThanOrEqual(Int64(residentAfter) - Int64(residentBefore), 65_536,
                                 "the resident size must not grow over the cycles")
        print("soak: descriptors \(descriptorsBefore) -> \(descriptorsAfter), resident \(residentBefore) -> \(residentAfter) bytes")
    }

    private func runPreviewCycle() {
        let handle = SketchyBarPreviewC.create()
        XCTAssertNotNil(handle)
        SketchyBarPreviewC.setDisplay(handle, widthPoints: 480, heightPoints: 25)
        SketchyBarPreviewC.addItem(handle, alias: "apple", position: "left")
        SketchyBarPreviewC.setItem(handle, alias: "apple", key: "width", value: "120")
        SketchyBarPreviewC.setItem(handle, alias: "apple", key: "label", value: "hello")
        SketchyBarPreviewC.setDefault(handle, key: "padding_left", value: "4")
        SketchyBarPreviewC.destroy(handle)
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
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<proc_fdinfo>.alignment)
        defer { buffer.deallocate() }

        let count = proc_pidinfo(getpid(), procPidListFds, 0, buffer, size)
        return Int(count)
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
