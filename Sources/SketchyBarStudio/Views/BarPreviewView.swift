import AppKit
import SwiftUI

struct BarPreviewView: View {
    @ObservedObject var store: SketchyBarStore
    let theme: AppTheme
    @State private var selectedItemID: ConfigFile.ID?

    var body: some View {
        let items = previewItems
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Draft Bar Preview", systemImage: "menubar.rectangle")
                    .font(.headline)
                    .foregroundStyle(theme.accent)

                Text("\(items.count) active items. Scroll each section; drag changes stay staged until Save.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if let selectedItem = items.first(where: { $0.id == selectedItemID }) {
                    PreviewAdjustmentControls(item: selectedItem, store: store, theme: theme)
                }
            }

            HStack(spacing: 8) {
                ForEach(BarPreviewPosition.allCases) { position in
                    previewColumn(position, items: items)
                }
            }
            .padding(8)
            .frame(height: 102)
            .background(theme.surface.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(theme.accent.opacity(0.55))
                    .frame(height: 1)
            }
        }
        .padding(16)
        .background(theme.background.opacity(0.34), in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: store.selectedFileID) { _, fileID in
            selectedItemID = fileID
        }
    }

    private var previewItems: [BarPreviewItem] {
        store.filesInPreviewOrder
            .filter { $0.isActive }
            .compactMap(BarPreviewItem.init(file:))
    }

    @ViewBuilder
    private func previewColumn(_ position: BarPreviewPosition, items: [BarPreviewItem]) -> some View {
        let columnItems = items.filter { $0.position == position }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(position.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(columnItems.count)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }

            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(columnItems) { item in
                        PreviewBarItem(
                            item: item,
                            isSelected: selectedItemID == item.id,
                            theme: theme,
                            onSelect: {
                                selectedItemID = item.id
                                store.selectedFileID = item.id
                            },
                            onResize: { width in
                                update(item.widthValue, to: width)
                            },
                            onDrop: { droppedID in
                                move(droppedID, before: item.id, to: position)
                            }
                        )
                    }
                }
                .frame(minWidth: 64, minHeight: 44, alignment: position.alignment)
            }
            .scrollIndicators(.visible)
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .padding(.horizontal, 6)
        .background(theme.background.opacity(columnItems.isEmpty ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 7))
        .dropDestination(for: String.self) { droppedIDs, _ in
            guard let droppedID = droppedIDs.first else { return false }
            return move(droppedID, before: nil, to: position)
        }
    }

    /// Moves an item to another column. The position and the loader order
    /// change together, so a rejected move changes nothing.
    @discardableResult
    private func move(_ droppedID: ConfigFile.ID, before targetID: ConfigFile.ID?, to position: BarPreviewPosition) -> Bool {
        guard droppedID != targetID else { return false }
        return store.moveItem(fileID: droppedID, before: targetID, to: position.rawValue)
    }

    private func update(_ value: LuaEditableValue?, to draftValue: String) {
        guard let value else { return }
        store.update(valueID: value.id, draftValue: draftValue)
    }
}

enum BarPreviewPosition: String, CaseIterable, Identifiable {
    case left
    case center
    case right

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var alignment: Alignment {
        switch self {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }
}

/// One item of the bar preview, with the values SketchyBar would use.
struct BarPreviewItem: Identifiable {
    let file: ConfigFile
    let position: BarPreviewPosition
    let positionValue: LuaEditableValue?
    let widthValue: LuaEditableValue?
    let leftPaddingValue: LuaEditableValue?
    let rightPaddingValue: LuaEditableValue?
    /// The icon of the item, read the way SketchyBar reads an icon value.
    let icon: SketchyBarIcon
    /// The color of the icon, when the config sets one.
    let iconColor: Color?
    /// The font of a text icon.
    let iconFont: NSFont
    /// The way an SF Symbol is drawn.
    let symbolMode: SketchyBarSymbolMode
    /// The color of an SF Symbol, when the config sets one.
    let symbolColor: Color?
    /// The scale of an SF Symbol, from 0 to 1.
    let symbolPercentage: Double
    /// The text of the label, when the config sets one.
    let labelText: String?
    /// The color of the label, when the config sets one.
    let labelColor: Color?
    /// The font of the label.
    let labelFont: NSFont
    /// The background of the item, when the config sets one.
    let backgroundColor: Color?
    /// The border of the item, when the config sets one.
    let borderColor: Color?
    /// The vertical offset of the item in points.
    let yOffset: CGFloat
    /// The name of the item, used when the config has no label.
    let title: String

    var id: ConfigFile.ID { file.id }

    init?(file: ConfigFile) {
        let values = file.values
        let lookup = Dictionary(values.map { ($0.keyPath.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })

        let positionValue = values.first { $0.leafKey == "position" }
        let fallbackPosition: BarPreviewPosition? = file.displayName.lowercased().contains("/left/") ? .left :
            file.displayName.lowercased().contains("/center/") ? .center :
            file.displayName.lowercased().contains("/right/") ? .right : nil
        guard let position = BarPreviewPosition(rawValue: positionValue?.draftValue.lowercased() ?? "") ?? fallbackPosition else {
            return nil
        }

        self.file = file
        self.position = position
        self.positionValue = positionValue
        widthValue = lookup["width"] ?? values.first { $0.leafKey == "width" }
        leftPaddingValue = lookup["padding_left"] ?? values.first { $0.leafKey == "padding_left" }
        rightPaddingValue = lookup["padding_right"] ?? values.first { $0.leafKey == "padding_right" }

        icon = SketchyBarIcon.parse((lookup["icon.string"] ?? lookup["icon"])?.draftValue ?? "")
        iconColor = Self.color(lookup["icon.color"] ?? lookup["icon_color"])
        symbolMode = SketchyBarSymbolMode(rawValue: (lookup["icon.symbol_mode"] ?? lookup["symbol_mode"])?.draftValue.lowercased() ?? "") ?? .automatic
        symbolColor = Self.color(lookup["icon.symbol_color"] ?? lookup["symbol_color"])
        symbolPercentage = Self.percentage(lookup["image.percentage"] ?? lookup["percentage"])

        let labelValue = lookup["label.string"] ?? lookup["label"]
        labelText = labelValue.flatMap { value -> String? in
            let text = value.draftValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        labelColor = Self.color(lookup["label.color"] ?? lookup["color"])
        labelFont = Self.font(lookup: lookup, prefixes: ["label.font", "font"]) ?? NSFont.systemFont(ofSize: 14)
        iconFont = Self.font(lookup: lookup, prefixes: ["icon.font", "font"]) ?? labelFont

        backgroundColor = Self.color(lookup["background.color"] ?? lookup["background_color"])
        borderColor = Self.color(lookup["background.border_color"] ?? lookup["border_color"])
        yOffset = CGFloat(lookup["y_offset"].flatMap { Double($0.draftValue) } ?? 0)

        title = labelText ?? file.url.deletingPathExtension().lastPathComponent
    }

    /// The color of a value, when the value holds a color SketchyBar reads.
    private static func color(_ value: LuaEditableValue?) -> Color? {
        value.flatMap { SketchyBarColor.parse($0.draftValue)?.color }
    }

    /// The scale of an SF Symbol. SketchyBar reads a value above 1 as a
    /// percentage.
    private static func percentage(_ value: LuaEditableValue?) -> Double {
        guard let number = value.flatMap({ Double($0.draftValue) }) else { return 1 }
        let scale = number > 1 ? number / 100 : number
        return min(max(scale, 0), 1)
    }

    /// The font of a value, read from the value of the domain or from the
    /// parts of the domain. A domain without a family keeps its size and
    /// uses the system font.
    private static func font(lookup: [String: LuaEditableValue], prefixes: [String]) -> NSFont? {
        for prefix in prefixes {
            if let value = lookup[prefix], let font = SketchyBarFont.parse(value.draftValue) {
                return SketchyBarFont.nsFont(family: font.family, style: font.style, size: font.size)
            }
            let family = lookup["\(prefix).family"]?.draftValue
            let style = lookup["\(prefix).style"]?.draftValue
            let sizeValue = lookup["\(prefix).size"]?.draftValue
            let size = sizeValue.flatMap { Double($0) }
            guard family != nil || style != nil || size != nil else { continue }
            return SketchyBarFont.nsFont(
                family: family ?? "",
                style: style ?? "Regular",
                size: size ?? 14
            )
        }
        return nil
    }
}

private struct PreviewBarItem: View {
    let item: BarPreviewItem
    let isSelected: Bool
    let theme: AppTheme
    let onSelect: () -> Void
    let onResize: (String) -> Void
    let onDrop: (String) -> Bool
    @State private var startingWidth: Double?

    var body: some View {
        HStack(spacing: 4) {
            PreviewIconView(item: item, theme: theme)

            if let labelText = item.labelText {
                Text(labelText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .font(Font(item.labelFont))
                    .foregroundStyle(item.labelColor ?? theme.accent)
                    .help(item.file.displayName)
                    .accessibilityLabel(labelText)
            } else {
                Text(item.title)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("The config has no label for this item, so the file name is shown.")
                    .accessibilityLabel(item.title)
            }

            if item.widthValue != nil {
                Rectangle()
                    .fill(theme.accent.opacity(0.8))
                    .frame(width: 3, height: 18)
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .gesture(resizeGesture)
                    .help("Drag to change width")
                    .accessibilityLabel("Resize \(item.title)")
                    .accessibilityValue(item.widthValue.map { "Width \($0.draftValue)" } ?? "")
            }
        }
        .padding(.leading, previewPadding(item.leftPaddingValue))
        .padding(.trailing, previewPadding(item.rightPaddingValue))
        .padding(.vertical, 7)
        .frame(width: displayWidth, alignment: .leading)
        .background(itemBackground, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(itemBorder, lineWidth: 1))
        .offset(y: -item.yOffset)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture(perform: onSelect)
        .draggable(item.id)
        .dropDestination(for: String.self) { droppedIDs, _ in
            guard let droppedID = droppedIDs.first else { return false }
            return onDrop(droppedID)
        }
    }

    private var itemBackground: Color {
        item.backgroundColor ?? theme.accent.opacity(isSelected ? 0.52 : 0.28)
    }

    private var itemBorder: Color {
        item.borderColor ?? theme.accent.opacity(isSelected ? 1 : 0.35)
    }

    private var displayWidth: CGFloat? {
        guard let width = numericValue(item.widthValue) else { return nil }
        return CGFloat(max(48, min(width, 150)))
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { gesture in
                guard let widthValue = item.widthValue,
                      let currentWidth = numericValue(widthValue) else { return }
                if startingWidth == nil {
                    startingWidth = currentWidth
                }
                let width = max(1, (startingWidth ?? currentWidth) + gesture.translation.width)
                onResize(format(width))
            }
            .onEnded { _ in
                startingWidth = nil
            }
    }
}

/// The icon of a preview item, drawn the way SketchyBar draws it.
private struct PreviewIconView: View {
    let item: BarPreviewItem
    let theme: AppTheme

    private let iconSize: CGFloat = 16

    var body: some View {
        switch item.icon.kind {
        case .symbol:
            symbol
        case .appIcon:
            appIcon
        case .mediaArtwork:
            mediaArtwork
        case .text:
            text
        case .unknown:
            unknown
        }
    }

    @ViewBuilder
    private var symbol: some View {
        if let name = item.icon.symbolName,
           SketchyBarIconImageCache.shared.image(for: item.icon) != nil {
            Image(systemName: name)
                .font(.system(size: iconSize * CGFloat(item.symbolPercentage)))
                .symbolRenderingMode(renderingMode)
                .foregroundStyle(symbolColor)
                .help("SF Symbol: \(name)")
                .accessibilityLabel("SF Symbol \(name)")
        } else {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(width: iconSize, height: iconSize)
                .help("SketchyBar would reject this symbol: Invalid SF Symbol name: '\(item.icon.symbolName ?? "")'")
                .accessibilityLabel("Warning: invalid SF Symbol")
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let image = SketchyBarIconImageCache.shared.image(for: item.icon) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSize, height: iconSize)
                .help("App icon: \(item.icon.bundleIdentifier ?? "")")
                .accessibilityLabel("App icon of \(item.icon.bundleIdentifier ?? "")")
        } else {
            Image(systemName: "app.dashed")
                .foregroundStyle(.secondary)
                .frame(width: iconSize, height: iconSize)
                .help("The app \(item.icon.bundleIdentifier ?? "") is not installed, so its icon cannot be shown.")
                .accessibilityLabel("App icon not found")
        }
    }

    private var mediaArtwork: some View {
        Image(systemName: "music.note")
            .foregroundStyle(.secondary)
            .frame(width: iconSize, height: iconSize)
            .help("The artwork of the playing song. The preview cannot show it.")
            .accessibilityLabel("Now playing artwork")
    }

    @ViewBuilder
    private var text: some View {
        if let text = item.icon.text {
            Text(text)
                .font(Font(item.iconFont))
                .foregroundStyle(item.iconColor ?? theme.accent)
                .help("Icon text: \(text)")
                .accessibilityLabel("Icon \(text)")
        }
    }

    private var unknown: some View {
        Image(systemName: "square.dashed")
            .foregroundStyle(.tertiary)
            .frame(width: iconSize, height: iconSize)
            .help("The config has no icon value for this item, so a placeholder is shown.")
            .accessibilityLabel("No icon")
    }

    private var renderingMode: SymbolRenderingMode {
        switch item.symbolMode {
        case .automatic: return .multicolor
        case .color, .draw: return .monochrome
        }
    }

    private var symbolColor: Color {
        switch item.symbolMode {
        case .automatic:
            return item.iconColor ?? theme.accent
        case .color:
            return item.symbolColor ?? item.iconColor ?? theme.accent
        case .draw:
            return item.iconColor ?? theme.accent
        }
    }
}

private struct PreviewAdjustmentControls: View {
    let item: BarPreviewItem
    @ObservedObject var store: SketchyBarStore
    let theme: AppTheme

    var body: some View {
        HStack(spacing: 8) {
            adjustment("Leading gap", value: item.leftPaddingValue)
            adjustment("Trailing gap", value: item.rightPaddingValue)
        }
    }

    @ViewBuilder
    private func adjustment(_ title: String, value: LuaEditableValue?) -> some View {
        if let value, let number = numericValue(value) {
            HStack(spacing: 3) {
                Button { update(value, to: number - 1) } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless)
                    .help("Decrease the \(title.lowercased())")
                    .accessibilityLabel("Decrease the \(title.lowercased())")
                Text("\(title) \(format(number))")
                    .font(.caption2)
                    .monospacedDigit()
                Button { update(value, to: number + 1) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Increase the \(title.lowercased())")
                    .accessibilityLabel("Increase the \(title.lowercased())")
            }
            .foregroundStyle(theme.accent)
        }
    }

    private func update(_ value: LuaEditableValue, to number: Double) {
        store.update(valueID: value.id, draftValue: format(max(0, number)))
    }
}

private extension LuaEditableValue {
    var leafKey: String {
        keyPath.lowercased().split(separator: ".").last.map(String.init) ?? keyPath.lowercased()
    }
}

private func numericValue(_ value: LuaEditableValue?) -> Double? {
    value.flatMap { Double($0.draftValue) }
}

private func previewPadding(_ value: LuaEditableValue?) -> CGFloat {
    CGFloat(max(0, min(numericValue(value) ?? 0, 18)))
}

private func format(_ value: Double) -> String {
    value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
}
