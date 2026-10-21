import Foundation

/// One property of a parsed config.
///
/// The key is the key path of the property, such as `label.string`, and the
/// value is the value the vendored core receives, such as `10:00`. The
/// value is the semantic value of the config, not its spelling: a string
/// does not keep its quotes.
struct BarRenderProperty: Hashable {
    /// The key path of the property, such as `label.string`.
    let key: String
    /// The value of the property, such as `10:00`.
    let value: String
}

/// The tree of a parsed config.
///
/// The tree holds the properties of the default item, the properties of the
/// bar and the items of the bar. The default item comes first, because
/// every item inherits it when it is created
/// (`src/bar_manager.c:463`, `src/bar_item.c:68`).
struct BarRenderPlan: Hashable {
    /// The properties of the default item.
    let defaults: [BarRenderProperty]
    /// The properties of the bar.
    let bar: [BarRenderProperty]
    /// The items of the bar, in the order of the config.
    let items: [BarRenderItemModel]
    /// The problems of the config that the bridge found while it read it.
    let warnings: [String]

    /// The plan of several files of one config.
    ///
    /// The defaults of every file are concatenated, so they all come
    /// before the first item of every file and an item inherits the
    /// defaults of the whole config, not only the defaults of its own
    /// file. The bar values are merged, the items are concatenated and
    /// the warnings are concatenated.
    func combined(with other: BarRenderPlan) -> BarRenderPlan {
        BarRenderPlan(
            defaults: defaults + other.defaults,
            bar: bar + other.bar,
            items: items + other.items,
            warnings: warnings + other.warnings
        )
    }
}
