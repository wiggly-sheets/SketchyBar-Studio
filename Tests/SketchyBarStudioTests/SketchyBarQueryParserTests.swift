import Foundation
import XCTest
@testable import SketchyBarStudio

/// The tests of the tolerant query parser.
final class SketchyBarQueryParserTests: XCTestCase {
    // MARK: - Valid JSON

    /// A valid JSON reply parses correctly.
    func testValidJSONParses() throws {
        let reply = """
        {
            "name": "test",
            "geometry": {
                "width": 100,
                "height": 25
            }
        }
        """
        let parsed = try SketchyBarQueryParser.parse(reply)
        XCTAssertEqual(parsed["name"] as? String, "test")
        XCTAssertEqual((parsed["geometry"] as? [String: Any])?["width"] as? Int, 100)
    }

    /// A reply with tab indentation parses correctly.
    func testTabIndentationParses() throws {
        let reply = """
        {
            "name": "test",
            "geometry": {
                "width": 100
            }
        }
        """
        let parsed = try SketchyBarQueryParser.parse(reply)
        XCTAssertEqual(parsed["name"] as? String, "test")
    }

    /// A reply with "on" / "off" strings parses correctly.
    func testOnOffStringsParse() throws {
        let reply = """
        {
            "geometry": {
                "drawing": "on",
                "scroll_texts": "off"
            }
        }
        """
        let parsed = try SketchyBarQueryParser.parse(reply)
        XCTAssertEqual((parsed["geometry"] as? [String: Any])?["drawing"] as? String, "on")
        XCTAssertEqual((parsed["geometry"] as? [String: Any])?["scroll_texts"] as? String, "off")
    }

    // MARK: - Backslash handling

    /// A value with a backslash is parsed by escaping it.
    func testBackslashInValueIsEscaped() throws {
        // In Swift string literals, \\\\ represents a literal backslash.
        // So "path\\\\to\\\\file" in Swift = "path\\to\\file" in the actual string.
        let reply = """
        {
            "geometry": {
                "label": {
                    "value": "path\\\\to\\\\file"
                }
            }
        }
        """
        let parsed = try SketchyBarQueryParser.parse(reply)
        let geometry = parsed["geometry"] as? [String: Any]
        let label = geometry?["label"] as? [String: Any]
        XCTAssertEqual(label?["value"] as? String, "path\\to\\file")
    }

    /// Multiple backslashes are all escaped.
    func testMultipleBackslashesAreEscaped() throws {
        // "a\\\\b\\\\c\\\\d" in Swift = "a\\b\\c\\d" in the actual string.
        let reply = """
        {
            "value": "a\\\\b\\\\c\\\\d"
        }
        """
        let parsed = try SketchyBarQueryParser.parse(reply)
        XCTAssertEqual(parsed["value"] as? String, "a\\b\\c\\d")
    }

    /// An already escaped backslash (double backslash) stays as is.
    func testAlreadyEscapedBackslashStays() throws {
        let reply = """
        {
            "value": "a\\\\b"
        }
        """
        let parsed = try SketchyBarQueryParser.parse(reply)
        // The JSON parser sees \\ as an escaped backslash, so it becomes a single backslash.
        XCTAssertEqual(parsed["value"] as? String, "a\\b")
    }

    /// Valid JSON escapes are not double-escaped.
    func testValidJSONEscapesAreNotDoubleEscaped() throws {
        let reply = """
        {
            "value": "line1\\nline2\\ttab"
        }
        """
        let parsed = try SketchyBarQueryParser.parse(reply)
        XCTAssertEqual(parsed["value"] as? String, "line1\nline2\ttab")
    }

    // MARK: - Error prefix

    /// The "[!] …" error prefix is detected and throws.
    func testErrorPrefixThrows() {
        let reply = "[!] The property 'not_a_property' is not a valid property."
        XCTAssertThrowsError(try SketchyBarQueryParser.parse(reply)) { error in
            guard case SketchyBarQueryParser.QueryError.errorReply(let message) = error else {
                XCTFail("expected errorReply, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("not_a_property"))
        }
    }

    /// parseError extracts the error message.
    func testParseErrorExtractsMessage() {
        let reply = "[!] The property 'not_a_property' is not a valid property."
        let extracted = SketchyBarQueryParser.parseError(reply)
        XCTAssertEqual(extracted, "The property 'not_a_property' is not a valid property.")
    }

    /// A valid reply does not trigger parseError.
    func testParseErrorReturnsNilForValidReply() {
        let reply = """
        {
            "name": "test"
        }
        """
        let extracted = SketchyBarQueryParser.parseError(reply)
        XCTAssertNil(extracted)
    }

    // MARK: - Missing keys

    /// Missing keys in the reply are tolerated (return nil).
    func testMissingKeysReturnNil() throws {
        let reply = """
        {
            "name": "test"
        }
        """
        let parsed = try SketchyBarQueryParser.parse(reply)
        XCTAssertNil(parsed["geometry"])
        XCTAssertNil(parsed["icon"])
    }

    /// Deeply missing keys are tolerated.
    func testDeeplyMissingKeysReturnNil() throws {
        let reply = """
        {
            "geometry": {
                "label": {}
            }
        }
        """
        let parsed = try SketchyBarQueryParser.parse(reply)
        XCTAssertNil((parsed["geometry"] as? [String: Any])?["icon"])
    }
}