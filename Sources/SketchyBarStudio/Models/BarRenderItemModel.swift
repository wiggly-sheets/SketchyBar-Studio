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

    init(alias: String,
         properties: [BarRenderProperty],
         addPosition: String? = nil) {
        self.alias = alias
        self.properties = properties
        self.addPosition = addPosition
    }
}
