import Foundation

/// The kind of value a SketchyBar option accepts.
enum SketchyBarOptionType: String {
    case boolean = "Boolean"
    case number = "Number"
    case color = "Color"
    case string = "String"
    case enumeration = "Enumeration"
    case font = "Font"
    case icon = "Icon"
}

/// Reference information for one SketchyBar option.
struct SketchyBarOptionDoc {
    let key: String
    let summary: String
    let type: SketchyBarOptionType
    /// The accepted values. An empty list means the value is free-form.
    let values: [String]
    /// The value SketchyBar uses when the option is not set.
    let defaultValue: String?
}

/// The option reference table.
///
/// The entries come from the SketchyBar sources: the property names in
/// `src/misc/defines.h` and the values that the `*_parse_sub_domain`
/// functions accept. Most keys are the leaf names SketchyBar uses, such as
/// `position` or `border_color`. Bar properties share their leaf names with
/// item properties, so `position` covers both the item position and the bar
/// position.
///
/// A few qualified keys are listed as well, for the options whose meaning or
/// default differs from the leaf name, such as `popup.height`.
enum SketchyBarOptionDocs {
    static let all: [SketchyBarOptionDoc] = [
        // MARK: Item properties

        entry("position", .enumeration,
              "Position of the item in the bar, of the bar on the screen, or popup.<item>.",
              values: ["left", "right", "center", "q", "e", "popup", "top", "bottom"]),
        entry("align", .enumeration,
              "Alignment of the content inside the item width.",
              values: ["left", "right", "center"], defaultValue: "left"),
        entry("width", .number,
              "Width of the item in points, or dynamic to fit the content.",
              values: ["dynamic"], defaultValue: "dynamic"),
        entry("drawing", .boolean,
              "Shows or hides the item.",
              values: ["on", "off"], defaultValue: "on"),
        entry("updates", .enumeration,
              "Lets the item update itself, and when.",
              values: ["on", "off", "when_shown"], defaultValue: "on"),
        entry("update_freq", .number,
              "Seconds between the runs of the item script.",
              defaultValue: "0"),
        entry("script", .string,
              "Shell script that fills the item with new values."),
        entry("click_script", .string,
              "Shell script that runs when the item is clicked."),
        entry("mach_helper", .string,
              "Name of a helper that sends events to the item directly."),
        entry("space", .string,
              "Space ids the item is shown on."),
        entry("display", .enumeration,
              "Displays the item is shown on.",
              values: ["all", "main", "active"]),
        entry("associated_display", .string,
              "Display ids the item follows."),
        entry("associated_space", .string,
              "Space ids the item follows."),
        entry("ignore_association", .boolean,
              "Keeps the item on every space and display.",
              values: ["on", "off"], defaultValue: "off"),
        entry("y_offset", .number,
              "Vertical offset of the item in points.", defaultValue: "0"),
        entry("x_offset", .number,
              "Horizontal offset of the content in points.", defaultValue: "0"),
        entry("padding_left", .number,
              "Padding left of the item in points.", defaultValue: "0"),
        entry("padding_right", .number,
              "Padding right of the item in points.", defaultValue: "0"),
        entry("blur_radius", .number,
              "Blur radius behind the item background.", defaultValue: "0"),
        entry("scroll_texts", .boolean,
              "Scrolls text that is longer than max_chars.",
              values: ["on", "off"], defaultValue: "off"),
        entry("line_break", .boolean,
              "Lets a long label break into more lines.",
              values: ["on", "off"], defaultValue: "off"),
        entry("shadow", .boolean,
              "Draws a shadow behind the item.",
              values: ["on", "off"], defaultValue: "off"),
        entry("max_chars", .number,
              "Number of characters shown before the text scrolls.", defaultValue: "0"),
        entry("scroll_duration", .number,
              "Time in milliseconds for one scroll step.", defaultValue: "100"),
        entry("lazy", .boolean,
              "Defers the first update of the item.",
              values: ["on", "off"], defaultValue: "on"),
        entry("cache_scripts", .boolean,
              "Keeps the scripts of the item cached between updates.",
              values: ["on", "off"]),
        entry("icon", .icon,
              "Icon shown for the item."),
        entry("label", .string,
              "Label shown for the item."),

        // MARK: Text properties (icon, label, badge, marker, knob)

        entry("string", .string,
              "Text that is drawn."),
        entry("value", .string,
              "Value of the component: the text of an icon or label, or a number for a ring."),
        entry("font", .font,
              "Font of the text.", defaultValue: "Hack Nerd Font:Bold:14.0"),
        entry("family", .string,
              "Font family of the text.", defaultValue: "Hack Nerd Font"),
        entry("style", .string,
              "Font style of the text, such as Bold or Italic.", defaultValue: "Bold"),
        entry("size", .number,
              "Font size of the text in points.", defaultValue: "14"),
        entry("features", .string,
              "OpenType features of the font."),
        entry("font_typographical_width", .boolean,
              "Uses the typographical width of the font.",
              values: ["on", "off"]),
        entry("color", .color,
              "Color of the text.", defaultValue: "0xffffffff"),
        entry("highlight", .boolean,
              "Uses the highlight color instead of the normal color.",
              values: ["on", "off"], defaultValue: "off"),
        entry("highlight_color", .color,
              "Color used while the text is highlighted.", defaultValue: "0xff000000"),
        entry("hex", .string,
              "Hex part of a color, such as ff8800."),
        entry("alpha", .number,
              "Alpha part of a color, from 0 to 255."),
        entry("red", .number,
              "Red part of a color, from 0 to 255."),
        entry("green", .number,
              "Green part of a color, from 0 to 255."),
        entry("blue", .number,
              "Blue part of a color, from 0 to 255."),

        // MARK: Background properties

        entry("background.color", .color,
              "Fill color of the background.", defaultValue: "0x00000000"),
        entry("background.drawing", .boolean,
              "Shows or hides the background.",
              values: ["on", "off"], defaultValue: "off"),
        entry("border_color", .color,
              "Color of the border.", defaultValue: "0x00000000"),
        entry("border_width", .number,
              "Width of the border in points.", defaultValue: "0"),
        entry("height", .number,
              "Height of the background in points.", defaultValue: "0"),
        entry("corner_radius", .number,
              "Corner radius of the background in points.", defaultValue: "0"),
        entry("clip", .number,
              "Amount the background clips the bar.", defaultValue: "0.0"),

        // MARK: Image properties

        entry("image", .string,
              "Image shown in the background."),
        entry("image.string", .string,
              "Image source, such as a file name or app.<bundle-id>."),
        entry("image.drawing", .boolean,
              "Shows or hides the image.",
              values: ["on", "off"], defaultValue: "off"),
        entry("scale", .number,
              "Scale factor of the image.", defaultValue: "1.0"),
        entry("rotation", .number,
              "Rotation of the image in degrees.", defaultValue: "0"),
        entry("percentage", .number,
              "Percentage value of the component, from 0 to 100."),
        entry("image.percentage", .number,
              "Opacity of the SF Symbol, from 0 to 1.", defaultValue: "1.0"),
        entry("symbol_color", .color,
              "Color of the SF Symbol."),
        entry("symbol_mode", .enumeration,
              "How the SF Symbol is drawn.",
              values: ["automatic", "color", "draw"], defaultValue: "automatic"),

        // MARK: Shadow properties

        entry("shadow.drawing", .boolean,
              "Shows or hides the shadow.",
              values: ["on", "off"], defaultValue: "off"),
        entry("shadow.color", .color,
              "Color of the shadow.", defaultValue: "0xff000000"),
        entry("angle", .number,
              "Angle of the shadow in degrees.", defaultValue: "30"),
        entry("distance", .number,
              "Distance of the shadow in points.", defaultValue: "5"),

        // MARK: Popup properties

        entry("popup.height", .number,
              "Height of a popup row in points.", defaultValue: "30"),
        entry("popup.drawing", .boolean,
              "Shows or hides the popup.",
              values: ["on", "off"], defaultValue: "off"),
        entry("popup.topmost", .boolean,
              "Keeps the popup above other windows.",
              values: ["on", "off"], defaultValue: "on"),
        entry("horizontal", .boolean,
              "Lays the popup out in rows instead of one column.",
              values: ["on", "off"], defaultValue: "off"),
        entry("cell_width", .number,
              "Width of a popup row in points.", defaultValue: "0"),
        entry("cell_padding", .number,
              "Padding inside a popup row in points.", defaultValue: "0"),
        entry("fill_row", .boolean,
              "Fills the full row width of a popup.",
              values: ["on", "off"], defaultValue: "off"),
        entry("columns", .number,
              "Number of columns of a popup.", defaultValue: "0"),

        // MARK: Badge, marker, knob, graph, ring, slider, alias

        entry("anchor", .enumeration,
              "Anchor point of the badge on the text.",
              values: ["top_left", "top_center", "top_right",
                       "center_left", "center", "center_right",
                       "bottom_left", "bottom_center", "bottom_right"],
              defaultValue: "bottom_right"),
        entry("badge.value", .string,
              "Text shown in the badge."),
        entry("marker.position", .enumeration,
              "Position of the marker on the ring.",
              values: ["start", "center"], defaultValue: "start"),
        entry("graph.color", .color,
              "Line color of the graph.", defaultValue: "0xffcccccc"),
        entry("fill_color", .color,
              "Fill color of the graph.", defaultValue: "0xffcccccc"),
        entry("line_width", .number,
              "Width of the graph line in points.", defaultValue: "0.5"),
        entry("ring.color", .color,
              "Color of the ring.", defaultValue: "0xffffffff"),
        entry("ring.value", .number,
              "Value of the ring, from 0 to 1.", defaultValue: "0"),
        entry("ring.line_width", .number,
              "Width of the ring line in points.", defaultValue: "2"),
        entry("ring.width", .number,
              "Diameter of the ring in points.", defaultValue: "20"),
        entry("track_color", .color,
              "Color of the ring track behind the value.", defaultValue: "0x33ffffff"),
        entry("start_angle", .number,
              "Angle where the ring starts, in degrees.", defaultValue: "270"),
        entry("clockwise", .boolean,
              "Draws the ring clockwise.",
              values: ["on", "off"], defaultValue: "on"),
        entry("cap", .enumeration,
              "Line cap of the ring.",
              values: ["round", "butt", "square"], defaultValue: "round"),
        entry("slider.width", .number,
              "Width of the slider in points.", defaultValue: "100"),
        entry("slider.highlight_color", .color,
              "Color of the filled part of the slider.", defaultValue: "0xff0000ff"),
        entry("alias.color", .color,
              "Color override for the alias icon."),
        entry("alias.scale", .number,
              "Scale factor of the alias icon.", defaultValue: "1.0"),
        entry("alias.update_freq", .number,
              "Seconds between the runs of the alias script.", defaultValue: "0"),

        // MARK: Bar properties

        entry("margin", .number,
              "Margin around the bar in points.", defaultValue: "0"),
        entry("topmost", .enumeration,
              "Keeps the bar above other windows.",
              values: ["off", "on", "window"], defaultValue: "off"),
        entry("sticky", .boolean,
              "Keeps the bar visible when it is not hovered.",
              values: ["on", "off"], defaultValue: "on"),
        entry("show_in_fullscreen", .boolean,
              "Shows the bar while a fullscreen app is in front.",
              values: ["on", "off"], defaultValue: "off"),
        entry("hidden", .enumeration,
              "Hides the bar, or only the current display.",
              values: ["off", "on", "current"], defaultValue: "off"),
        entry("font_smoothing", .boolean,
              "Smooths the fonts of the bar.",
              values: ["on", "off"], defaultValue: "off"),
        entry("notch_width", .number,
              "Width of the notch gap in points.", defaultValue: "200"),
        entry("notch_offset", .number,
              "Offset of the notch gap in points.", defaultValue: "0"),
        entry("notch_display_height", .number,
              "Height of the notch gap in points.", defaultValue: "0"),

        // MARK: Keys of the Lua module
        //
        // These keys belong to the SketchyBar Lua module, not to the
        // SketchyBar binary, so the sources do not list accepted values.

        entry("id", .string,
              "Identifier of the item."),
        entry("properties", .string,
              "Properties of the item, set as a table."),
        entry("mouse", .boolean,
              "Mouse events of the item.",
              values: ["on", "off"]),
        entry("content_update", .string,
              "Content of the item that a script updates."),
        entry("content_replace", .string,
              "Content of the item that a script replaces."),
        entry("stack.symbol", .icon,
              "Symbol shown by the stack."),
        entry("stack.size", .number,
              "Size of the stack."),
        entry("stack.spacing", .number,
              "Spacing between the items of the stack."),
        entry("stack.hidden", .boolean,
              "Hides the stack.",
              values: ["on", "off"]),
        entry("stack.empty", .boolean,
              "Draws the stack when it holds no item.",
              values: ["on", "off"])
    ]

    private static let byKey: [String: SketchyBarOptionDoc] = {
        var table: [String: SketchyBarOptionDoc] = [:]
        for doc in all {
            table[doc.key] = doc
        }
        return table
    }()

    /// Finds the reference entry of a key path.
    ///
    /// The full qualified key wins, so `icon.font.size` finds its own entry
    /// when it has one. Otherwise the leaf key is used, so `icon.font.size`
    /// falls back to `size` and `background.border_color` falls back to
    /// `border_color`.
    static func doc(for keyPath: String) -> SketchyBarOptionDoc? {
        let key = keyPath.lowercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        if let exact = byKey[key] {
            return exact
        }
        guard let leaf = key.split(separator: ".").last.map(String.init) else {
            return nil
        }
        return byKey[leaf]
    }

    private static func entry(
        _ key: String,
        _ type: SketchyBarOptionType,
        _ summary: String,
        values: [String] = [],
        defaultValue: String? = nil
    ) -> SketchyBarOptionDoc {
        SketchyBarOptionDoc(
            key: key,
            summary: summary,
            type: type,
            values: values,
            defaultValue: defaultValue
        )
    }
}
