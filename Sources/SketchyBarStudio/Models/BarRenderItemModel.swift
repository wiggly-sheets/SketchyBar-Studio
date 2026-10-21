import Foundation

/// One item of a parsed config.
///
/// The alias is the name of the item, such as `clock`, and the properties
/// are the property assignments the item gets, in the order of the config.
struct BarRenderItemModel: Hashable {
    /// The alias of the item, such as `clock`.
    let alias: String
    /// The properties of the item, in the order of the config.
    let properties: [BarRenderProperty]
    /// The position that the add command carries, when it has one.
    ///
    /// The shell style carries the position in the add command, so it is
    /// not a property of the item. The daemon takes the position of the
    /// first add of an alias (`src/message.c:190-193`), so the position of
    /// a later add is ignored.
    let addPosition: String?
    /// The type of the add command, such as `item` or `bracket`.
    ///
    /// The type is the first argument of the add command of the daemon
    /// (`src/message.c:196`). The daemon knows `item`, `alias`, `space`,
    /// `graph`, `slider` and `bracket`, and it creates no item at all for
    /// an `event` (`src/message.c:175-185`).
    let type: String
    /// The trailing argument of the add command.
    ///
    /// The daemon reads it after the position (`src/message.c:218-256`):
    /// the width of a graph and of a slider, and the members of a bracket.
    let argument: String?

    init(alias: String,
         properties: [BarRenderProperty],
         addPosition: String? = nil,
         type: String = "item",
         argument: String? = nil) {
        self.alias = alias
        self.properties = properties
        self.addPosition = addPosition
        self.type = type
        self.argument = argument
    }
}
