import AppKit
import CoreGraphics
import SwiftUI

/// The preview pane of the rendered bar.
///
/// The bar is rendered by the vendored SketchyBar code, so the pane shows
/// the bar as SketchyBar would draw it. The image is drawn at the true
/// point size of the bar and the view applies one uniform factor that fits
/// the pane, so the proportions of the real menu bar survive. The 1:1
/// control shows the bar at its true point size, so one image pixel lands
/// on one device pixel of a display with the scale of 2.0, and the pane
/// scrolls sideways.
///
/// The pane is also the editor of the bar: the rendered items are hit
/// targets. Clicking one selects it, double-clicking it opens its file,
/// dragging it moves it along the bar, and dragging the handle of a
/// selected item resizes it. The inspector under the image edits the
/// properties of the selected item, and the values reach the same drafts as
/// the structured editor, so the simulation is live.
struct BarRenderView: View {
    /// The axis the pane scrolls on.
    ///
    /// The pane always scrolls sideways, because the bar of a display is
    /// wider than the pane at its true size.
    static let scrollAxis: Axis.Set = .horizontal

    @ObservedObject var store: SketchyBarStore
    let theme: AppTheme
    @ObservedObject var state: BarRenderState
    @State private var isOneToOne = false
    @Binding var selectedAlias: String?
    @FocusState private var isBarFocused: Bool
    /// True after the first render synced the selection of the store.
    ///
    /// The first render arrives after the pane appears, so the selection of
    /// the store is applied once. Afterwards the selection belongs to the
    /// user: a deselected item stays deselected across renders.
    @State private var hasSyncedInitialSelection = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            liveBarNote
            BarRenderProfilePicker(store: store, theme: theme)
            imagePane
            inspector
            messages
        }
        .padding(16)
        .liquidGlassSurface(
            cornerRadius: 12,
            tint: theme.background.opacity(0.18),
            fallback: theme.background.opacity(0.34)
        )
        .task(id: requestKey) {
            // The render runs the Lua plan and paints the bitmap, and a
            // keystroke changes the drafts. The short wait collapses a run of
            // keystrokes into one render: the task is cancelled when the key
            // changes again, so only the newest text is rendered.
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            await renderCurrent()
        }
        .onReceive(Self.liveValuesTimer) { _ in refreshLiveValues() }
        .onDisappear {
            Task { await BarRendererService.shared.stopLiveValues() }
        }
        .onChange(of: store.selectedFileID) { _, _ in syncSelectionFromStore() }
        .onAppear { syncSelectionFromStore() }
        .onChange(of: state.renderRevision) { _, _ in
            guard !hasSyncedInitialSelection else { return }
            hasSyncedInitialSelection = true
            syncSelectionFromStore()
        }
        .onChange(of: effectiveSource) { _, _ in
            selectedAlias = nil
            hasSyncedInitialSelection = false
        }
    }

    /// The timer that looks for new values of the scripts of the items.
    ///
    /// The service runs the scripts on its own timer and bumps a revision
    /// when they produced values. The simulation reads the revision and
    /// renders again only when it changed, so the bar really follows its
    /// scripts without repainting the bar for nothing.
    private static let liveValuesTimer = Timer
        .publish(every: 1, on: .main, in: .common)
        .autoconnect()

    private var header: some View {
        HStack {
            Label("Live Simulation", systemImage: "menubar.rectangle")
                .font(.headline)
                .foregroundStyle(theme.accent)

            Spacer()

            if store.liveBarIsWorking {
                ProgressView()
                    .controlSize(.small)
                    .help("Writing the live bar. This can take a moment on a large config.")
            }

            LiveUpdateModePicker(store: store)

            Toggle("1:1", isOn: $isOneToOne)
                .toggleStyle(.checkbox)
                .help("Show the bar at its true point size, so one image pixel lands on one device pixel of a display with the scale of 2.0. The pane scrolls sideways then.")
        }
    }

    /// What the live bar does now, and what the user can do about it.
    private var liveBarNote: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(store.liveUpdateMode.explanation)
                .font(.caption)
                .foregroundStyle(theme.muted)

            if store.liveBarHasSnapshot {
                Label("The live bar was changed by this app. The Restore button in the toolbar puts it back.",
                      systemImage: "arrow.uturn.backward")
                    .font(.caption)
                    .foregroundStyle(theme.accent)
            }

            if !store.liveBarMessage.isEmpty {
                Text(store.liveBarMessage)
                    .font(.caption)
                    .foregroundStyle(theme.muted)
            }
        }
    }

    private var imagePane: some View {
        GeometryReader { proxy in
            ScrollView(Self.scrollAxis) {
                imageView(in: proxy.size)
                    .frame(minWidth: proxy.size.width, maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(height: 120)
        .background(theme.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.accent.opacity(0.55))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func imageView(in paneSize: CGSize) -> some View {
        if let image = state.image {
            let layout = BarRenderLayout(imageSize: state.pixelSize,
                                         paneSize: paneSize,
                                         isOneToOne: isOneToOne)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: layout.drawnSize.width, height: layout.drawnSize.height)

                if isEditable, let frame = state.barFrame {
                    SimulationOverlay(store: store,
                                      theme: theme,
                                      layout: layout,
                                      barWidth: frame.width,
                                      barRects: state.barRelativeRects,
                                      origins: state.itemOrigins,
                                      selectedAlias: $selectedAlias,
                                      onOpen: openInEditor)
                }
            }
            .frame(width: layout.drawnSize.width, height: layout.drawnSize.height, alignment: .topLeading)
            .coordinateSpace(name: SimulationCoordinateSpace.name)
            .contentShape(Rectangle())
            .focusable()
            .focused($isBarFocused)
            .onMoveCommand(perform: moveSelected)
            .onExitCommand {
                selectedAlias = nil
                isBarFocused = false
            }
            .dropDestination(for: String.self) { droppedAliases, location in
                drop(droppedAliases, at: location, layout: layout, barWidth: frameWidth)
            }
        } else {
            Text(state.isRendering ? "Rendering the bar..." : "No bar to show yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// True when the rendered source is the config the app has open, so an
    /// edit of the simulation reaches a draft.
    private var isEditable: Bool {
        guard case .config(let id) = effectiveSource else { return false }
        return id == store.selectedConfig?.id
    }

    /// The width of the bar in points, which is the width of the image
    /// divided by the backing scale of 2.0.
    private var frameWidth: CGFloat {
        state.barFrame?.width ?? (state.pixelSize.width / BarRenderLayout.bitmapScale)
    }

    @ViewBuilder
    private var inspector: some View {
        if isEditable {
            if let selectedAlias,
               let file = store.configFile(for: state.itemOrigins[selectedAlias]) {
                SimulationItemInspector(store: store,
                                        theme: theme,
                                        alias: selectedAlias,
                                        file: file,
                                        onOpen: { openInEditor(selectedAlias) },
                                        onClose: { self.selectedAlias = nil })
            } else {
                SimulationBarInspector(store: store, theme: theme)
            }
        } else {
            Label("This bar is shown as it is on disk. Open its config to edit it in the simulation.",
                  systemImage: "lock")
                .font(.caption)
                .foregroundStyle(theme.muted)
        }
    }

    @ViewBuilder
    private var messages: some View {
        if let failure = state.failure {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
        } else if !state.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(state.warnings.enumerated()), id: \.offset) { _, warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// What the render depends on: the source, the display and the files
    /// of that source.
    ///
    /// The key changes with every draft of the config the app has open,
    /// and with every change on disk of a config that is not open, so the
    /// bar is rendered again when the rendered source really changed.
    private var requestKey: Int {
        var hasher = Hasher()
        hasher.combine(effectiveSource)
        hasher.combine(store.barRenderDisplayID)
        hasher.combine(store.barRenderWidthOverride)
        hasher.combine(store.barRenderSignature(for: effectiveSource))
        // The signature above follows the text of the files. The order and
        // the activation of the items are structure, not text, so a drag or
        // an activation toggle has to be part of the key as well.
        hasher.combine(store.filesInPreviewOrder.map(\.id))
        hasher.combine(store.filesInPreviewOrder.map(\.isActive))
        return hasher.finalize()
    }

    /// The source the pane renders.
    private var effectiveSource: BarRenderSource? {
        if let source = store.barRenderSource { return source }
        return BarRenderChoices.defaultSource(configs: store.configs,
                                              openConfigID: store.selectedConfig?.id)
    }

    /// The display the bar is rendered for.
    ///
    /// The width of that display is the width of the virtual display, so
    /// the bar has the proportions of the real menu bar of that display: a
    /// SketchyBar bar is the display width minus twice the margin
    /// (`src/bar.c:437-494`).
    private func targetDisplay() -> BarRenderDisplay? {
        let displays = BarRenderDisplays.all()
        if let id = store.barRenderDisplayID,
           let display = displays.first(where: { $0.id == id }) {
            return display
        }
        if let main = BarRenderDisplays.main(),
           let display = displays.first(where: { $0.id == main.id }) {
            return display
        }
        return displays.first
    }

    /// Renders the bar of the current source.
    @MainActor
    private func renderCurrent() async {
        guard let source = effectiveSource else { return }
        let display = targetDisplay()
        let width = store.barRenderWidthOverride ?? display?.widthPoints ?? 1440
        let request = BarRenderRequest(
            files: store.barRenderFiles(for: source),
            root: store.barRenderRoot(for: source),
            fileOrder: store.barRenderFileOrder(for: source),
            filesAreInFileOrder: store.barRenderFilesAreInFileOrder(for: source),
            displayWidthPoints: width,
            displayHeightPoints: display?.heightPoints ?? 900,
            warnings: store.barRenderWarnings(for: source)
        )
        await state.render(request)
    }

    /// Renders again when the scripts of the items produced new values.
    private func refreshLiveValues() {
        guard state.hasScripts, !state.isRendering else { return }
        Task {
            await BarRendererService.shared.keepAlive()
            let revision = await BarRendererService.shared.liveValuesRevision
            guard revision != state.liveValuesRevision else { return }
            await renderCurrent()
        }
    }

    /// Selects the item of the bar that belongs to the file of the store.
    ///
    /// A file can declare more than one item. The item of the first
    /// declaration wins, so the selection does not jump between items after
    /// a render.
    private func syncSelectionFromStore() {
        guard let fileID = store.selectedFileID else {
            selectedAlias = nil
            return
        }
        // A file can declare more than one item. When the user picked the
        // second item, the store points at the same file, and the pick must
        // survive the change of the store selection.
        if let selectedAlias,
           store.configFile(for: state.itemOrigins[selectedAlias])?.id == fileID {
            return
        }
        selectedAlias = alias(for: fileID)
    }

    /// The item of the simulation that belongs to a file.
    ///
    /// Only an item the bar really draws is picked: a popup item or an item
    /// of another display keeps the nirvana rectangle.
    private func alias(for fileID: ConfigFile.ID) -> String? {
        state.itemOrigins
            .filter { alias, origin in
                guard store.configFile(for: origin)?.id == fileID else { return false }
                return isDrawable(state.barRelativeRects[alias])
            }
            .min { $0.value.index < $1.value.index }?
            .key
    }

    /// True when the rectangle is inside the bar the simulation draws.
    ///
    /// The x axis is enough: an item the bar does not draw keeps the
    /// nirvana rectangle far to the left of the bar.
    private func isDrawable(_ rect: CGRect?) -> Bool {
        guard let rect, rect.width > 0 else { return false }
        return rect.midX >= 0 && rect.midX <= frameWidth
    }

    /// Opens the file of an item in the structured editor.
    private func openInEditor(_ alias: String) {
        guard let file = store.configFile(for: state.itemOrigins[alias]) else { return }
        selectedAlias = alias
        store.selectedFileID = file.id
        store.detailPaneMode = .edit
    }

    /// Moves or resizes the selected item with the arrow keys.
    ///
    /// The left and right arrows move the item in its loader, and the up and
    /// down arrows change a numeric width. The keys only act on a selected
    /// item that really has a file.
    private func moveSelected(_ direction: MoveCommandDirection) {
        guard let alias = selectedAlias,
              let file = store.configFile(for: state.itemOrigins[alias]) else { return }
        switch direction {
        case .left:
            store.moveItem(fileID: file.id, direction: .up)
        case .right:
            store.moveItem(fileID: file.id, direction: .down)
        case .up, .down:
            guard let width = file.values.last(where: {
                $0.keyPath.lowercased() == "width" && Double($0.draftValue) != nil
            }) else { return }
            let current = Double(width.draftValue) ?? 1
            let next = direction == .up ? current + 1 : current - 1
            store.update(valueID: width.id, draftValue: String(max(1, Int(next.rounded()))))
        @unknown default:
            break
        }
    }

    /// Moves the dropped item to the position and the place of the drop.
    ///
    /// The drop lands on the rendered bar, so the third of the bar the
    /// pointer is over is the position, and the nearest item of that third
    /// is the place the item goes before. An empty third only changes the
    /// position.
    private func drop(_ aliases: [String], at location: CGPoint, layout: BarRenderLayout, barWidth: CGFloat) -> Bool {
        guard isEditable, let payload = aliases.first else { return false }
        // A drag can come from the simulation (the alias) or from the
        // sidebar (the path of the file). Both land on the same item.
        let candidate = store.configFile(for: state.itemOrigins[payload])
            ?? store.files.first { $0.url.path == payload }
        guard let file = candidate else { return false }
        let rects = state.barRelativeRects.filter { alias, _ in
            store.configFile(for: state.itemOrigins[alias])?.id != file.id
        }
        let points = SimulationGeometry.barPoints(forDrawn: location, layout: layout)
        let position = SimulationDrop.position(forX: points.x, barWidth: barWidth)
        let target = SimulationDrop.target(forX: points.x,
                                           position: position,
                                           barWidth: barWidth,
                                           rects: rects)
        let targetFileID = target.flatMap { store.configFile(for: state.itemOrigins[$0.alias])?.id }
        if let target, let targetFileID {
            return target.after
                ? store.moveItem(fileID: file.id, after: targetFileID, to: position.rawValue)
                : store.moveItem(fileID: file.id, before: targetFileID, to: position.rawValue)
        }
        return store.moveItem(fileID: file.id, before: nil, to: position.rawValue)
    }
}

/// The coordinate space the simulation gestures use.
enum SimulationCoordinateSpace {
    /// The space of the drawn bar. A drag is measured against this space, so
    /// a handle that moves under the pointer does not change the width it
    /// already produced.
    static let name = "sketchybar-simulation"
}

/// The geometry of the interactive layer of the simulation.
enum SimulationGeometry {
    /// The point of the bar under a point of the drawn image.
    ///
    /// The image is the bar at the fixed backing scale of 2.0, and the view
    /// draws it at one uniform factor, so the number of drawn points per
    /// point of the bar is the factor of the layout times the scale.
    static func barPoints(forDrawn point: CGPoint, layout: BarRenderLayout) -> CGPoint {
        let pointsPerBarPoint = pointsPerBarPoint(layout: layout)
        guard pointsPerBarPoint > 0 else { return .zero }
        return CGPoint(x: point.x / pointsPerBarPoint, y: point.y / pointsPerBarPoint)
    }

    /// The rectangle of an item of the bar in the drawn image.
    static func drawnRect(forBarRect rect: CGRect, layout: BarRenderLayout) -> CGRect {
        let factor = pointsPerBarPoint(layout: layout)
        return CGRect(x: rect.origin.x * factor,
                      y: rect.origin.y * factor,
                      width: rect.width * factor,
                      height: rect.height * factor)
    }

    /// The number of drawn points per point of the bar.
    static func pointsPerBarPoint(layout: BarRenderLayout) -> CGFloat {
        let barWidthPoints = layout.imageSize.width / BarRenderLayout.bitmapScale
        guard barWidthPoints > 0 else { return 0 }
        return layout.drawnSize.width / barWidthPoints
    }
}

/// Where an item goes when it is dropped on the bar.
enum SimulationDrop {
    /// The position of the drop: the third of the bar the pointer is over.
    ///
    /// The bar lays its items out as left, center and right, so the thirds
    /// are the positions the drop can pick. The center third is generous:
    /// an item is dropped where the pointer is, not where the item happens
    /// to be.
    static func position(forX x: CGFloat, barWidth: CGFloat) -> BarPreviewPosition {
        guard barWidth > 0 else { return .left }
        let ratio = x / barWidth
        if ratio < 1.0 / 3.0 { return .left }
        if ratio > 2.0 / 3.0 { return .right }
        return .center
    }

    /// The item a drop goes before or after, when the bar has one.
    ///
    /// The target is the first item of the position whose centre is to the
    /// right of the drop. A drop to the right of every item of the position
    /// targets the last item `after` it.
    static func target(forX x: CGFloat,
                       position: BarPreviewPosition,
                       barWidth: CGFloat,
                       rects: [String: CGRect]) -> (alias: String, after: Bool)? {
        let candidates = rects
            .filter { $0.value.width > 0 && $0.value.midX >= 0 && $0.value.midX <= barWidth }
            .filter { Self.position(forX: $0.value.midX, barWidth: barWidth) == position }
            .sorted { $0.value.midX < $1.value.midX }
        guard !candidates.isEmpty else { return nil }
        if let first = candidates.first(where: { $0.value.midX >= x }) {
            return (first.key, false)
        }
        return candidates.last.map { ($0.key, true) }
    }

    /// The alias of the item a drop goes before, when the bar has one.
    ///
    /// Kept for the tests and for callers that only need the name.
    static func targetAlias(forX x: CGFloat,
                            position: BarPreviewPosition,
                            barWidth: CGFloat,
                            rects: [String: CGRect]) -> String? {
        target(forX: x, position: position, barWidth: barWidth, rects: rects)?.alias
    }
}

/// The click, drag and resize layer over the rendered bar.
private struct SimulationOverlay: View {
    @ObservedObject var store: SketchyBarStore
    let theme: AppTheme
    let layout: BarRenderLayout
    let barWidth: CGFloat
    let barRects: [String: CGRect]
    let origins: [String: BarRenderOrigin]
    @Binding var selectedAlias: String?
    let onOpen: (String) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The empty part of the bar clears the selection. It sits under
            // the items, so a click on an item never reaches it.
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .frame(width: layout.drawnSize.width, height: layout.drawnSize.height)
                .onTapGesture { selectedAlias = nil }

            ForEach(orderedAliases, id: \.self) { alias in
                if let barRect = barRects[alias] {
                    let rect = SimulationGeometry.drawnRect(forBarRect: barRect, layout: layout)
                    itemOverlay(alias: alias, rect: rect)
                }
            }

            if let alias = selectedAlias,
               let barRect = barRects[alias],
               let widthValue = widthValue(for: alias) {
                let rect = SimulationGeometry.drawnRect(forBarRect: barRect, layout: layout)
                SimulationResizeHandle(theme: theme,
                                       value: widthValue,
                                       height: max(12, rect.height),
                                       pointsPerBarPoint: SimulationGeometry.pointsPerBarPoint(layout: layout),
                                       onResize: { store.update(valueID: widthValue.id, draftValue: $0) })
                    .offset(x: rect.maxX - 4, y: rect.minY)
            }
        }
        .frame(width: layout.drawnSize.width, height: layout.drawnSize.height, alignment: .topLeading)
    }

    /// The aliases in the order of the bar, so the overlays stack the way
    /// the items are drawn.
    private var orderedAliases: [String] {
        barRects
            .filter { $0.value.width > 0 && $0.value.midX >= 0 && $0.value.midX <= barWidth }
            .keys
            .sorted { lhs, rhs in
                (barRects[lhs]?.minX ?? 0) < (barRects[rhs]?.minX ?? 0)
            }
    }

    private func itemOverlay(alias: String, rect: CGRect) -> some View {
        let isSelected = selectedAlias == alias
        return RoundedRectangle(cornerRadius: 4)
            .fill(isSelected ? theme.accent.opacity(0.26) : Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isSelected ? theme.accent : theme.accent.opacity(0.24),
                            lineWidth: isSelected ? 2 : 1)
            }
            .frame(width: max(1, rect.width), height: max(1, rect.height))
            .contentShape(Rectangle())
            .offset(x: rect.minX, y: rect.minY)
            .onTapGesture(count: 2) {
                onOpen(alias)
            }
            .onTapGesture {
                selectedAlias = alias
                if let file = store.configFile(for: origins[alias]) {
                    store.selectedFileID = file.id
                }
            }
            .draggable(alias)
            .help(helpText(for: alias))
            .accessibilityElement()
            .accessibilityLabel("Item \(alias)")
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
            .accessibilityAction {
                selectedAlias = alias
                if let file = store.configFile(for: origins[alias]) {
                    store.selectedFileID = file.id
                }
            }
            .accessibilityAction(named: "Edit file") { onOpen(alias) }
            .contextMenu {
                if let file = store.configFile(for: origins[alias]) {
                    Button("Edit \(file.displayName)") { onOpen(alias) }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([file.url])
                    }
                    if file.activationReference != nil {
                        Divider()
                        Button("Move Earlier") {
                            store.moveItem(fileID: file.id, direction: .up)
                        }
                        Button("Move Later") {
                            store.moveItem(fileID: file.id, direction: .down)
                        }
                        Button("Deactivate \(alias)") {
                            store.setActive(false, fileID: file.id)
                        }
                    }
                    if let width = widthValue(for: alias) {
                        Divider()
                        Button("Wider") {
                            let current = Double(width.draftValue) ?? 1
                            store.update(valueID: width.id, draftValue: String(Int(current.rounded()) + 1))
                        }
                        Button("Narrower") {
                            let current = Double(width.draftValue) ?? 1
                            store.update(valueID: width.id, draftValue: String(max(1, Int(current.rounded()) - 1)))
                        }
                    }
                }
            }
    }

    /// The width value of the item, when it has a numeric width.
    private func widthValue(for alias: String) -> LuaEditableValue? {
        guard let file = store.configFile(for: origins[alias]) else { return nil }
        return file.values.last {
            $0.keyPath.lowercased() == "width" && Double($0.draftValue) != nil
        }
    }

    private func helpText(for alias: String) -> String {
        guard let file = store.configFile(for: origins[alias]) else {
            return "\(alias): click to select. Drag to move."
        }
        return "\(alias) — \(file.displayName)\nClick to select, drag to move, double-click to edit the file."
    }
}

/// The handle that resizes an item of the rendered bar.
///
/// The handle only appears when the item has a numeric width, because a
/// dynamic width has no number to change. The drag is in the points of the
/// bar, so the width the user sees is the width the bar gets.
private struct SimulationResizeHandle: View {
    let theme: AppTheme
    let value: LuaEditableValue
    let height: CGFloat
    let pointsPerBarPoint: CGFloat
    let onResize: (String) -> Void

    @State private var startingWidth: Double?
    @State private var startLocation: CGFloat?

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(theme.accent)
            .frame(width: 7, height: height)
            .contentShape(Rectangle().inset(by: -4))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(SimulationCoordinateSpace.name))
                    .onChanged { gesture in
                        guard pointsPerBarPoint > 0 else { return }
                        if startingWidth == nil {
                            startingWidth = Double(value.draftValue) ?? 0
                            startLocation = gesture.location.x
                        }
                        // The gesture is in the space of the bar, and the
                        // start point is kept, so a handle that moves with
                        // the drag stays under the pointer instead of
                        // feeding its own movement back into the width.
                        let delta = Double((gesture.location.x - (startLocation ?? gesture.location.x))
                            / pointsPerBarPoint)
                        let width = max(1, (startingWidth ?? 0) + delta)
                        onResize(format(width.rounded()))
                    }
                    .onEnded { _ in
                        startingWidth = nil
                        startLocation = nil
                    }
            )
            .help("Drag to change the width of \(value.keyPath)")
            .accessibilityLabel("Resize width")
            .accessibilityValue(value.draftValue)
            .accessibilityAdjustableAction { direction in
                let current = Double(value.draftValue) ?? 1
                switch direction {
                case .increment:
                    onResize(format(max(1, current + 1)))
                case .decrement:
                    onResize(format(max(1, current - 1)))
                @unknown default:
                    break
                }
            }
    }

    private func format(_ number: Double) -> String {
        number.rounded() == number ? String(Int(number)) : String(format: "%.1f", number)
    }
}

/// The inspector of the selected item of the simulation.
private struct SimulationItemInspector: View {
    @ObservedObject var store: SketchyBarStore
    let theme: AppTheme
    let alias: String
    let file: ConfigFile
    let onOpen: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(alias, systemImage: "cursorarrow.click.2")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.accent)

                Text(file.displayName)
                    .font(.caption)
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button("Edit Values", action: onOpen)
                    .help("Open this item in the structured editor")

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.muted)
                .help("Deselect the item")
                .accessibilityLabel("Deselect the item")
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)],
                      alignment: .leading,
                      spacing: 8) {
                field("Position", value: value(["position"], leaf: "position")) { value in
                    Picker("Position", selection: binding(for: value)) {
                        ForEach(BarPreviewPosition.allCases) { position in
                            Text(position.rawValue).tag(position.rawValue)
                        }
                        if !BarPreviewPosition.allCases.contains(where: {
                            $0.rawValue == value.draftValue.lowercased()
                        }) {
                            Text(value.draftValue).tag(value.draftValue)
                        }
                    }
                    .labelsHidden()
                }

                field("Label", value: value(["label.string", "label"], leaf: "label")) { value in
                    TextField("Label", text: binding(for: value))
                        .textFieldStyle(.roundedBorder)
                }

                field("Icon", value: value(["icon.string", "icon"], leaf: "icon.string")) { value in
                    TextField("Icon", text: binding(for: value))
                        .textFieldStyle(.roundedBorder)
                }

                field("Width", value: file.values.last { $0.keyPath.lowercased() == "width" }) { value in
                    TextField("Width", text: binding(for: value))
                        .textFieldStyle(.roundedBorder)
                }

                field("Background", value: value(["background.color", "background_color"], leaf: "background.color")) { value in
                    colorField(value)
                }

                field("Label color", value: value(["label.color", "color"], leaf: "label.color")) { value in
                    colorField(value)
                }

                field("Icon color", value: value(["icon.color", "icon_color"], leaf: "icon.color")) { value in
                    colorField(value)
                }
            }
        }
        .padding(12)
        .background(theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(theme.accent.opacity(0.35), lineWidth: 1)
        }
    }

    /// One inspector field. The field is only shown when the config sets the
    /// value, because a missing value cannot be written safely from here.
    @ViewBuilder
    private func field<Content: View>(_ title: String,
                                      value: LuaEditableValue?,
                                      @ViewBuilder content: (LuaEditableValue) -> Content) -> some View {
        if let value {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(theme.muted)
                content(value)
            }
        }
    }

    private func colorField(_ value: LuaEditableValue) -> some View {
        HStack(spacing: 6) {
            ColorPicker("Color",
                        selection: Binding(
                            get: { Color(hexLike: value.draftValue) },
                            set: { store.update(valueID: value.id, draftValue: SketchyBarColor.hexString(from: $0, preservingFormatOf: value.draftValue)) }),
                        supportsOpacity: true)
                .labelsHidden()

            TextField("Color", text: binding(for: value))
                .textFieldStyle(.roundedBorder)
        }
    }

    private func binding(for value: LuaEditableValue) -> Binding<String> {
        Binding(
            get: { value.draftValue },
            set: { store.update(valueID: value.id, draftValue: $0) }
        )
    }

    /// The value of the item for one of the names the config uses.
    ///
    /// The exact key paths win, so `label.color` is never read as the color
    /// of the item, and the leaf is only a fallback for a value that the
    /// scanner writes without its domain.
    private func value(_ keyPaths: [String], leaf: String) -> LuaEditableValue? {
        let wanted = keyPaths.map { $0.lowercased() }
        if let exact = file.values.last(where: { wanted.contains($0.keyPath.lowercased()) }) {
            return exact
        }
        let loweredLeaf = leaf.lowercased()
        return file.values.last {
            let path = $0.keyPath.lowercased()
            return path == loweredLeaf || path.hasSuffix("." + loweredLeaf)
        }
    }
}

/// The inspector of the bar itself, shown when no item is selected.
private struct SimulationBarInspector: View {
    @ObservedObject var store: SketchyBarStore
    let theme: AppTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Bar", systemImage: "rectangle.topthird.inset.filled")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.accent)

                Text("Click an item of the rendered bar to edit it.")
                    .font(.caption)
                    .foregroundStyle(theme.muted)

                Spacer()
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)],
                      alignment: .leading,
                      spacing: 8) {
                field("Position", key: "position") { value in
                    Picker("Position", selection: binding(for: value)) {
                        Text("top").tag("top")
                        Text("bottom").tag("bottom")
                        if !["top", "bottom"].contains(value.draftValue.lowercased()) {
                            Text(value.draftValue).tag(value.draftValue)
                        }
                    }
                    .labelsHidden()
                }

                field("Height", key: "height") { value in
                    TextField("Height", text: binding(for: value))
                        .textFieldStyle(.roundedBorder)
                }

                field("Margin", key: "margin") { value in
                    TextField("Margin", text: binding(for: value))
                        .textFieldStyle(.roundedBorder)
                }

                field("Left padding", key: "padding_left") { value in
                    TextField("Left padding", text: binding(for: value))
                        .textFieldStyle(.roundedBorder)
                }

                field("Right padding", key: "padding_right") { value in
                    TextField("Right padding", text: binding(for: value))
                        .textFieldStyle(.roundedBorder)
                }

                field("Color", key: "color") { value in
                    HStack(spacing: 6) {
                        ColorPicker("Color",
                                    selection: Binding(
                                        get: { Color(hexLike: value.draftValue) },
                                        set: { store.update(valueID: value.id, draftValue: SketchyBarColor.hexString(from: $0, preservingFormatOf: value.draftValue)) }),
                                    supportsOpacity: true)
                            .labelsHidden()

                        TextField("Color", text: binding(for: value))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
        .padding(12)
        .background(theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(theme.accent.opacity(0.18), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func field<Content: View>(_ title: String,
                                      key: String,
                                      @ViewBuilder content: (LuaEditableValue) -> Content) -> some View {
        if let value = store.barValue(key) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(theme.muted)
                content(value)
            }
        }
    }

    private func binding(for value: LuaEditableValue) -> Binding<String> {
        Binding(
            get: { value.draftValue },
            set: { store.update(valueID: value.id, draftValue: $0) }
        )
    }
}

/// The picker of the mode of the live bar.
///
/// The picker is always on: the mode is a setting, so the user must be
/// able to go back to `Never` at any time, also when the preview does
/// not show the live config of SketchyBar. The reason the push is off
/// sits under the picker, and the store refuses the push anyway.
struct LiveUpdateModePicker: View {
    @ObservedObject var store: SketchyBarStore

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Picker("Live bar", selection: $store.liveUpdateMode) {
                ForEach(LiveUpdateMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .frame(width: 150)
            .help(help)

            if let reason = store.liveBarBlockedReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
        }
    }

    /// The help of the picker.
    private var help: String {
        if let reason = store.liveBarBlockedReason { return reason }
        return "How the live bar of SketchyBar follows the edits of the app. \(store.liveUpdateMode.explanation)"
    }
}

/// The state of the rendered bar.
///
/// The render runs off the main actor and the image comes back to the main
/// actor. Every render gets a number, and the result of an older render is
/// dropped, so a slow render cannot overwrite a newer one.
@MainActor
final class BarRenderState: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published private(set) var pixelSize: CGSize = .zero
    @Published private(set) var warnings: [String] = []
    @Published private(set) var isRendering = false
    @Published private(set) var failure: String?
    /// The rectangles of the items, relative to the bar, in the points of
    /// the bar. The simulation uses them as its hit targets.
    @Published private(set) var barRelativeRects: [String: CGRect] = [:]
    /// The frame of the bar, in the points of the display.
    @Published private(set) var barFrame: CGRect?
    /// The file that declared each item of the bar.
    @Published private(set) var itemOrigins: [String: BarRenderOrigin] = [:]
    /// True when at least one item of the bar has a script.
    @Published private(set) var hasScripts = false
    /// Bumped after every successful render, so the simulation can follow
    /// the selection of the store again.
    @Published private(set) var renderRevision = 0
    /// The revision of the values of the scripts that the shown image has.
    private(set) var liveValuesRevision = 0

    /// The number of the newest render. A result of an older render is
    /// dropped.
    private var generation = 0

    func render(_ request: BarRenderRequest) async {
        generation &+= 1
        let token = generation
        isRendering = true
        failure = nil

        do {
            let result = try await BarRendererService.shared.render(request)
            guard !Task.isCancelled, token == generation else {
                if token == generation { isRendering = false }
                return
            }
            image = result.image
            pixelSize = result.pixelSize
            warnings = result.warnings
            barRelativeRects = result.barRelativeRects
            barFrame = result.barFrame
            itemOrigins = result.itemOrigins
            hasScripts = result.hasScripts
            liveValuesRevision = result.liveValuesRevision
            renderRevision &+= 1
            isRendering = false
        } catch {
            guard !Task.isCancelled, token == generation else {
                if token == generation { isRendering = false }
                return
            }
            // The last good image stays on screen: a transient failure of
            // the preview core must not blank the bar the user is editing.
            // The banner says that the shown bar is not the newest one.
            failure = error.localizedDescription
            isRendering = false
        }
    }
}
