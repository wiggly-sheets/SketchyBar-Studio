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

struct BarPreviewItem: Identifiable {
    let file: ConfigFile
    let position: BarPreviewPosition
    let positionValue: LuaEditableValue?
    let widthValue: LuaEditableValue?
    let leftPaddingValue: LuaEditableValue?
    let rightPaddingValue: LuaEditableValue?
    let title: String

    var id: ConfigFile.ID { file.id }

    init?(file: ConfigFile) {
        let positionValue = file.values.first { $0.leafKey == "position" }
        let fallbackPosition: BarPreviewPosition? = file.displayName.lowercased().contains("/left/") ? .left :
            file.displayName.lowercased().contains("/center/") ? .center :
            file.displayName.lowercased().contains("/right/") ? .right : nil
        guard let position = BarPreviewPosition(rawValue: positionValue?.draftValue.lowercased() ?? "") ?? fallbackPosition else {
            return nil
        }

        self.file = file
        self.position = position
        self.positionValue = positionValue
        widthValue = file.values.first { $0.keyPath == "width" } ?? file.values.first { $0.leafKey == "width" }
        leftPaddingValue = file.values.first { $0.leafKey == "padding_left" }
        rightPaddingValue = file.values.first { $0.leafKey == "padding_right" }
        let configuredTitle = file.values
            .first(where: { $0.leafKey == "label" || $0.leafKey == "icon" })?
            .draftValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        title = configuredTitle.flatMap { $0.isEmpty ? nil : $0 } ?? file.url.deletingPathExtension().lastPathComponent
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
            Text(item.title)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .font(.caption.weight(.medium))
                .help(item.file.displayName)
                .accessibilityLabel(item.title)

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
        .background(theme.accent.opacity(isSelected ? 0.52 : 0.28), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.accent.opacity(isSelected ? 1 : 0.35), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture(perform: onSelect)
        .draggable(item.id)
        .dropDestination(for: String.self) { droppedIDs, _ in
            guard let droppedID = droppedIDs.first else { return false }
            return onDrop(droppedID)
        }
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
