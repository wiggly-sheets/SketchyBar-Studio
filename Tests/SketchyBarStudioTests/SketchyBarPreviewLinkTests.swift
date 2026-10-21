import Foundation
@testable import SketchyBarStudio
import XCTest

/// The link proof of the vendored SketchyBar preview core.
///
/// The test covers the handle lifecycle only: the handle is created and
/// destroyed without a crash. The item tree, the messages and the rendered
/// image belong to stage 2 and stage 4.
final class SketchyBarPreviewLinkTests: XCTestCase {
    func testPreviewHandleLifecycle() {
        let handle = SketchyBarPreviewC.create()
        XCTAssertNotNil(handle, "the vendored core must hand out a preview handle")

        SketchyBarPreviewC.destroy(handle)
    }

    /// Many create and destroy cycles in a row. A double free or a use after
    /// free shows up here as a crash.
    ///
    /// There is no memory assertion on purpose. The soak test that watches
    /// the resident size belongs to stage 2, where the item tree exists.
    /// Adding an item to the preview is blocked on the stage 2 API, so the
    /// loop stays on the handle.
    func testPreviewHandleCreateDestroyLoop() {
        for iteration in 0..<200 {
            let handle = SketchyBarPreviewC.create()
            XCTAssertNotNil(handle, "iteration \(iteration) must hand out a preview handle")

            SketchyBarPreviewC.destroy(handle)
        }
    }
}
