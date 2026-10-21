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
}
