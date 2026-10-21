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

/// The draft of the app: the items the parser reads from the text of the
/// files of a config.
///
/// Every item knows the file that declared it and the number of the
/// declaration inside that file, so the draft of a file can be put on the
/// item of the resolved config that the file declared.
struct BarRenderDraft: Hashable {
    /// The items of the draft, in the order of the files.
    let items: [BarRenderDraftItem]

    /// The item of a place, when the draft has one.
    ///
    /// The file and the number name the declaration: the parser counts the
    /// calls of `sbar.add` of the file and the resolver counts them the
    /// same way. The name of the item confirms it, so a draft never lands
    /// on the item of another declaration.
    ///
    /// A file that declares its items in a loop or behind a condition does
    /// not line up, because the calls of the file run more than once or
    /// not at all. The name of the item names the declaration then.
    ///
    /// An item whose name the parser cannot read, such as a name that an
    /// expression builds, has no match: the app does not invent one.
    func item(at origin: BarRenderOrigin, alias: String) -> BarRenderDraftItem? {
        guard !alias.isEmpty else { return nil }
        if let item = items.first(where: { $0.origin == origin && $0.alias == alias }) {
            return item
        }
        return items.first(where: { $0.origin.file == origin.file && $0.alias == alias })
    }
}

/// One item of a draft.
struct BarRenderDraftItem: Hashable {
    /// The place the item was declared.
    let origin: BarRenderOrigin
    /// The alias of the item, empty when the item has no name.
    let alias: String
    /// The values the parser can read.
    let properties: [BarRenderProperty]
    /// The values the parser cannot read, such as an expression.
    let unreadable: [BarRenderUnreadableValue]
}

/// A value of a draft that the app cannot read.
///
/// A value that is built by an expression, such as `colors.red`, needs a
/// Lua interpreter to be read. The app cannot run the draft, so it keeps
/// the value of the resolved config and says so.
struct BarRenderUnreadableValue: Hashable {
    /// The key path of the value, such as `icon.color`.
    let keyPath: String
    /// How the value was written.
    let kind: LuaLiteralKind
}

extension BarRenderPlan {
    /// The plan with the draft of the app on top.
    ///
    /// The draft wins for every value it changes: the value of the draft
    /// is the value the user wrote, and the preview shows it. A value the
    /// draft cannot read, such as an expression, keeps the value of the
    /// resolved config, and the warning says so.
    ///
    /// A draft of an item that the resolved config does not have is
    /// reported: the item was typed after the config was resolved, so the
    /// preview cannot show it.
    ///
    /// The plan of the parser has no origin on its items, so the draft
    /// changes nothing there: the path of the parser reads the text of the
    /// files itself.
    func overlaying(draft: BarRenderDraft) -> BarRenderPlan {
        guard !draft.items.isEmpty else { return self }

        var warnings = warnings
        var items = items
        var matched: Set<BarRenderOrigin> = []

        for index in items.indices {
            guard let origin = items[index].origin else { continue }
            guard let drafted = draft.item(at: origin, alias: items[index].alias) else { continue }
            matched.insert(drafted.origin)
            items[index] = items[index].overlaying(draft: drafted, warnings: &warnings)
        }

        for drafted in draft.items where !matched.contains(drafted.origin) {
            // An item whose name the parser cannot read has no match, and
            // the app does not invent one.
            guard !drafted.alias.isEmpty else { continue }
            warnings.append(PreviewWarning.draftItemWithoutResolved(alias: drafted.alias,
                                                                     file: drafted.origin.file,
                                                                     isInTheConfig: items.contains { $0.alias == drafted.alias }))
        }

        return BarRenderPlan(defaults: defaults, bar: bar, items: items, warnings: warnings)
    }
}

extension BarRenderItemModel {
    /// The item with the draft of the app on top.
    ///
    /// A value the draft changes wins: it is the value the user wrote. A
    /// value the draft cannot read, such as an expression, keeps the value
    /// of the resolved config, and the warning says so.
    func overlaying(draft: BarRenderDraftItem, warnings: inout [String]) -> BarRenderItemModel {
        var properties = properties

        for index in properties.indices {
            // A value the draft cannot read keeps the value of the
            // resolved config, and the pane says so.
            if let unreadable = draft.unreadable.first(where: { $0.keyPath == properties[index].key }) {
                warnings.append(PreviewWarning.draftValueUnreadable(unreadable, alias: alias))
                continue
            }
            guard let drafted = draft.properties.first(where: { $0.key == properties[index].key }) else { continue }
            let value = PreviewValue.drafted(drafted.value, keyPath: properties[index].key)
            if value != properties[index].value {
                properties[index] = BarRenderProperty(key: properties[index].key, value: value)
            }
        }

        // The values the draft adds: the user typed them, so the preview
        // shows them.
        for drafted in draft.properties where !properties.contains(where: { $0.key == drafted.key }) {
            properties.append(BarRenderProperty(key: drafted.key,
                                                value: PreviewValue.drafted(drafted.value, keyPath: drafted.key)))
        }

        return BarRenderItemModel(alias: alias,
                                   properties: properties,
                                   addPosition: addPosition,
                                   type: type,
                                   argument: argument,
                                   origin: origin)
    }
}
