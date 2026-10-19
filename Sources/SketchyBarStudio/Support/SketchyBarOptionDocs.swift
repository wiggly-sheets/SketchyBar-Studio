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
/// The entries follow the SketchyBar sources: the property names in
/// `src/misc/defines.h`, the values that the `*_parse_sub_domain` functions
/// accept and the defaults of `src/bar_manager.c` and the `*_init`
/// functions. Only the properties that the binary really parses have an
/// entry, so the reference never names a property that SketchyBar answers
/// with `Invalid property`.
///
/// A property that exists on the item and on the bar has one entry per
/// level, such as `position` and `bar.position`, so a summary always says
/// which level it describes. A summary that does not name a level means
/// that the property has the same meaning on every level.
///
/// The values of a boolean option are the ones the app writes, `true` and
/// `false`. SketchyBar also accepts `on`, `off`, `yes`, `no`, `1`, `0` and
/// `toggle` for them.
enum SketchyBarOptionDocs {
    static let all: [SketchyBarOptionDoc] = [
        // MARK: Item properties

        entry("position", .enumeration,
              "Item level. Place of the item in the bar: left, right, center, q (center left), e (center right), or popup.<item> to show the item in the popup of another item.",
              values: ["left", "right", "center", "q", "e"], defaultValue: "left"),
        entry("align", .enumeration,
              "Item, text and popup level. Alignment of the content inside the width. The bar has no align property.",
              values: ["left", "right", "center"], defaultValue: "left"),
        entry("width", .number,
              "Width of the item in points, or dynamic to fit the content.",
              defaultValue: "dynamic"),
        entry("drawing", .boolean,
              "Item level. Shows or hides the item.",
              values: ["true", "false"], defaultValue: "true"),
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
              "Space ids the item is shown on, separated by commas."),
        entry("display", .enumeration,
              "Item level. Displays the item is shown on: a display id such as 1, or active for the display in front. The bar level takes all and main as well, see bar.display.",
              values: ["active"]),
        entry("associated_display", .string,
              "Display ids the item follows, separated by commas."),
        entry("associated_space", .string,
              "Space ids the item follows, separated by commas."),
        entry("ignore_association", .boolean,
              "Keeps the item on every space and display.",
              values: ["true", "false"], defaultValue: "false"),
        entry("y_offset", .number,
              "Vertical offset of the item in points.", defaultValue: "0"),
        entry("x_offset", .number,
              "Horizontal offset of the content in points.", defaultValue: "0"),
        entry("padding_left", .number,
              "Item level. Padding left of the item in points.", defaultValue: "0"),
        entry("padding_right", .number,
              "Item level. Padding right of the item in points.", defaultValue: "0"),
        entry("blur_radius", .number,
              "Blur radius behind the item background.", defaultValue: "0"),
        entry("scroll_texts", .boolean,
              "Scrolls text that is longer than max_chars.",
              values: ["true", "false"], defaultValue: "false"),
        entry("line_break", .boolean,
              "Lets a long label break into more lines.",
              values: ["true", "false"], defaultValue: "false"),
        entry("shadow", .boolean,
              "Draws a shadow behind the item, or behind the whole bar on the bar level.",
              values: ["true", "false"], defaultValue: "false"),
        entry("max_chars", .number,
              "Number of characters shown before the text scrolls.", defaultValue: "0"),
        entry("scroll_duration", .number,
              "Frames of one scroll step at 60 frames per second, so 100 is about 1.7 seconds.",
              defaultValue: "100"),
        entry("icon", .icon,
              "Icon shown for the item."),
        entry("label", .string,
              "Label shown for the item."),

        // MARK: Text properties (icon, label, badge)

        entry("string", .string,
              "Text that is drawn."),
        entry("value", .string,
              "Text of an icon, a label or a badge."),
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
              values: ["true", "false"], defaultValue: "false"),
        entry("color", .color,
              "Item level. Color of the text.", defaultValue: "0xffffffff"),
        entry("highlight", .boolean,
              "Uses the highlight color instead of the normal color.",
              values: ["true", "false"], defaultValue: "false"),
        entry("highlight_color", .color,
              "Color used while the text is highlighted.", defaultValue: "0xff000000"),
        entry("hex", .string,
              "Hex part of a color, such as 0xff8800. The 0x prefix is needed, because SketchyBar reads the value as a number."),
        entry("alpha", .number,
              "Alpha part of a color, from 0 to 1."),
        entry("red", .number,
              "Red part of a color, from 0 to 1."),
        entry("green", .number,
              "Green part of a color, from 0 to 1."),
        entry("blue", .number,
              "Blue part of a color, from 0 to 1."),

        // MARK: Icon and label properties
        //
        // The icon and the label are text components, so they take the
        // text properties above. These entries name the component the
        // property belongs to.

        entry("icon.string", .string,
              "Text that is drawn as the icon."),
        entry("icon.color", .color,
              "Color of the icon text.", defaultValue: "0xffffffff"),
        entry("icon.drawing", .boolean,
              "Shows or hides the icon text.",
              values: ["true", "false"], defaultValue: "true"),
        entry("icon.highlight", .boolean,
              "Uses the highlight color instead of the normal color.",
              values: ["true", "false"], defaultValue: "false"),
        entry("icon.highlight_color", .color,
              "Color used while the icon is highlighted.", defaultValue: "0xff000000"),
        entry("icon.font", .font,
              "Font of the icon text.", defaultValue: "Hack Nerd Font:Bold:14.0"),
        entry("icon.font.family", .string,
              "Font family of the icon text.", defaultValue: "Hack Nerd Font"),
        entry("icon.font.style", .string,
              "Font style of the icon text, such as Bold or Italic.", defaultValue: "Bold"),
        entry("icon.font.size", .number,
              "Font size of the icon text in points.", defaultValue: "14"),
        entry("icon.width", .number,
              "Width of the icon in points, or dynamic to fit the content.",
              defaultValue: "dynamic"),
        entry("label.string", .string,
              "Text that is drawn as the label."),
        entry("label.color", .color,
              "Color of the label text.", defaultValue: "0xffffffff"),
        entry("label.drawing", .boolean,
              "Shows or hides the label text.",
              values: ["true", "false"], defaultValue: "true"),
        entry("label.highlight", .boolean,
              "Uses the highlight color instead of the normal color.",
              values: ["true", "false"], defaultValue: "false"),
        entry("label.highlight_color", .color,
              "Color used while the label is highlighted.", defaultValue: "0xff000000"),
        entry("label.font", .font,
              "Font of the label text.", defaultValue: "Hack Nerd Font:Bold:14.0"),
        entry("label.font.family", .string,
              "Font family of the label text.", defaultValue: "Hack Nerd Font"),
        entry("label.font.style", .string,
              "Font style of the label text, such as Bold or Italic.", defaultValue: "Bold"),
        entry("label.font.size", .number,
              "Font size of the label text in points.", defaultValue: "14"),
        entry("font.family", .string,
              "Font family of the text.", defaultValue: "Hack Nerd Font"),
        entry("font.style", .string,
              "Font style of the text, such as Bold or Italic.", defaultValue: "Bold"),
        entry("font.size", .number,
              "Font size of the text in points.", defaultValue: "14"),

        // MARK: Background properties

        entry("background.color", .color,
              "Fill color of the background.", defaultValue: "0x00000000"),
        entry("background.drawing", .boolean,
              "Shows or hides the background.",
              values: ["true", "false"], defaultValue: "false"),
        entry("background.border_color", .color,
              "Color of the border of the background.", defaultValue: "0x00000000"),
        entry("background.border_width", .number,
              "Width of the border of the background in points.", defaultValue: "0"),
        entry("background.corner_radius", .number,
              "Corner radius of the background in points.", defaultValue: "0"),
        entry("background.height", .number,
              "Height of the background in points. A height of 0 uses the height of the bar.",
              defaultValue: "0"),
        entry("background.clip", .number,
              "Amount the background clips the bar, from 0 to 1.", defaultValue: "0.0"),
        entry("background.image", .string,
              "Image shown in the background, such as a file name or app.<bundle-id>."),
        entry("border_color", .color,
              "Item level. Color of the border of the background.", defaultValue: "0x00000000"),
        entry("border_width", .number,
              "Width of the border in points.", defaultValue: "0"),
        entry("height", .number,
              "Item level. Height of the background in points. A height of 0 uses the height of the bar.",
              defaultValue: "0"),
        entry("corner_radius", .number,
              "Corner radius of the background in points.", defaultValue: "0"),
        entry("clip", .number,
              "Amount the background clips the bar, from 0 to 1.", defaultValue: "0.0"),

        // MARK: Image properties

        entry("image", .string,
              "Image shown in the background."),
        entry("image.string", .string,
              "Image source, such as a file name or app.<bundle-id>."),
        entry("image.drawing", .boolean,
              "Shows or hides the image.",
              values: ["true", "false"], defaultValue: "false"),
        entry("scale", .number,
              "Scale factor of the image.", defaultValue: "1.0"),
        entry("rotation", .number,
              "Rotation of the image in degrees.", defaultValue: "0"),
        entry("percentage", .number,
              "Percentage of the ring or the slider, from 0 to 100. The SF Symbol of an image takes 0 to 1."),
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
              values: ["true", "false"], defaultValue: "false"),
        entry("shadow.color", .color,
              "Color of the shadow.", defaultValue: "0xff000000"),
        entry("angle", .number,
              "Angle of the shadow in degrees.", defaultValue: "30"),
        entry("distance", .number,
              "Distance of the shadow in points.", defaultValue: "5"),

        // MARK: Popup properties

        entry("popup.height", .number,
              "Height of a popup row in points. The default is the height of the bar window."),
        entry("popup.drawing", .boolean,
              "Shows or hides the popup.",
              values: ["true", "false"], defaultValue: "false"),
        entry("popup.topmost", .boolean,
              "Keeps the popup above other windows.",
              values: ["true", "false"], defaultValue: "true"),
        entry("popup.horizontal", .boolean,
              "Lays the popup out in rows instead of one column.",
              values: ["true", "false"], defaultValue: "false"),
        entry("popup.fill_row", .boolean,
              "Fills the full row width of a popup.",
              values: ["true", "false"], defaultValue: "false"),
        entry("popup.columns", .number,
              "Number of columns of a popup.", defaultValue: "0"),
        entry("popup.cell_width", .number,
              "Width of a popup row in points.", defaultValue: "0"),
        entry("popup.cell_padding", .number,
              "Padding inside a popup row in points.", defaultValue: "0"),
        entry("popup.background.color", .color,
              "Fill color of the popup background.", defaultValue: "0x44000000"),
        entry("popup.background.border_color", .color,
              "Color of the border of the popup background.", defaultValue: "0xffff0000"),
        entry("horizontal", .boolean,
              "Popup level. Lays the popup out in rows instead of one column.",
              values: ["true", "false"], defaultValue: "false"),
        entry("cell_width", .number,
              "Popup level. Width of a popup row in points.", defaultValue: "0"),
        entry("cell_padding", .number,
              "Popup level. Padding inside a popup row in points.", defaultValue: "0"),
        entry("fill_row", .boolean,
              "Popup level. Fills the full row width of a popup.",
              values: ["true", "false"], defaultValue: "false"),
        entry("columns", .number,
              "Popup level. Number of columns of a popup.", defaultValue: "0"),

        // MARK: Badge, marker, knob, graph, ring, slider, alias

        entry("anchor", .enumeration,
              "Anchor point of the badge on the text. These are the canonical names, SketchyBar also accepts top_centre, centre_left, left_center, right_center, bottom_centre and centre.",
              values: ["top_left", "top_center", "top_right",
                       "center_left", "center", "center_right",
                       "bottom_left", "bottom_center", "bottom_right"],
              defaultValue: "bottom_right"),
        entry("badge.value", .string,
              "Text shown in the badge."),
        entry("marker.position", .enumeration,
              "Position of the marker on the ring. SketchyBar also accepts centre.",
              values: ["start", "center"], defaultValue: "start"),
        entry("ring.marker.position", .enumeration,
              "Position of the marker on the ring. SketchyBar also accepts centre.",
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
              values: ["true", "false"], defaultValue: "true"),
        entry("cap", .enumeration,
              "Line cap of the ring.",
              values: ["round", "butt", "square"], defaultValue: "round"),
        entry("slider.width", .number,
              "Width of the slider in points.", defaultValue: "100"),
        entry("slider.highlight_color", .color,
              "Color of the filled part of the slider.", defaultValue: "0xff0000ff"),
        entry("slider.background.color", .color,
              "Fill color of the slider background.", defaultValue: "0xff000000"),
        entry("alias.color", .color,
              "Color override for the alias icon."),
        entry("alias.scale", .number,
              "Scale factor of the alias icon.", defaultValue: "1.0"),
        entry("alias.update_freq", .number,
              "Seconds between the runs of the alias script.", defaultValue: "0"),

        // MARK: Bar properties
        //
        // These properties belong to the bar and not to an item. The
        // properties that exist on both levels have a `bar.` entry with
        // the default of the bar.

        entry("margin", .number,
              "Bar level. Margin around the bar in points.", defaultValue: "0"),
        entry("topmost", .enumeration,
              "Bar level. Keeps the bar above other windows. The value window puts the bar at the window level.",
              values: ["off", "on", "window"], defaultValue: "off"),
        entry("sticky", .boolean,
              "Bar level. Keeps the bar visible when it is not hovered.",
              values: ["true", "false"], defaultValue: "true"),
        entry("show_in_fullscreen", .boolean,
              "Bar level. Shows the bar while a fullscreen app is in front.",
              values: ["true", "false"], defaultValue: "false"),
        entry("hidden", .enumeration,
              "Bar level. Hides the bar, or only the display in front.",
              values: ["off", "on", "current"], defaultValue: "off"),
        entry("font_smoothing", .boolean,
              "Bar level. Smooths the fonts of the bar.",
              values: ["true", "false"], defaultValue: "false"),
        entry("notch_width", .number,
              "Bar level. Width of the notch gap in points.", defaultValue: "200"),
        entry("notch_offset", .number,
              "Bar level. Offset of the notch gap in points.", defaultValue: "0"),
        entry("notch_display_height", .number,
              "Bar level. Height of the notch gap in points.", defaultValue: "0"),
        entry("bar.color", .color,
              "Bar level. Fill color of the bar background.", defaultValue: "0x44000000"),
        entry("bar.border_color", .color,
              "Bar level. Color of the border of the bar background.", defaultValue: "0xffff0000"),
        entry("bar.height", .number,
              "Bar level. Height of the bar in points.", defaultValue: "25"),
        entry("bar.padding_left", .number,
              "Bar level. Padding left of the bar in points.", defaultValue: "20"),
        entry("bar.padding_right", .number,
              "Bar level. Padding right of the bar in points.", defaultValue: "20"),
        entry("bar.position", .enumeration,
              "Bar level. Place of the bar on the screen.",
              values: ["top", "bottom"], defaultValue: "top"),
        entry("bar.display", .enumeration,
              "Bar level. Displays the bar is shown on: all, main, or a display id such as 1.",
              values: ["all", "main"], defaultValue: "all")
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
