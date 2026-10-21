import SwiftUI

/// One choice of the preview picker: a config of the library or a saved
/// profile of a config.
struct BarRenderChoice: Identifiable, Hashable {
    let source: BarRenderSource
    /// The name of the config or of the profile.
    let title: String
    /// The name in the menu of the picker.
    ///
    /// Two configs can have a profile of the same name, so the menu of a
    /// profile carries the config it belongs to.
    let menuTitle: String
    /// Where it lives, for the user.
    let detail: String
    /// True when the choice is the config the app has open, so the render
    /// shows the unsaved drafts.
    let isOpen: Bool

    var id: String { source.id }
}

/// The choices of the preview picker.
enum BarRenderChoices {
    /// Every config of the library and every saved profile of every config.
    static func make(configs: [ConfigWorkspace],
                     profiles: [BarRenderProfile],
                     openConfigID: ConfigWorkspace.ID?) -> [BarRenderChoice] {
        var choices = configs.map { config in
            BarRenderChoice(source: .config(config.id),
                            title: config.name,
                            menuTitle: config.name,
                            detail: config.path,
                            isOpen: config.id == openConfigID)
        }

        choices += profiles.map { entry in
            BarRenderChoice(source: .profile(profilePath: entry.profile.id),
                            title: entry.profile.name,
                            menuTitle: "\(entry.profile.name) — \(entry.config.name)",
                            detail: "Saved profile of \(entry.config.name)",
                            isOpen: false)
        }

        return choices
    }

    /// The choice the picker starts with: the config the app has open.
    ///
    /// A config that is not the open one has no drafts in the store, so the
    /// picker starts with the config the user is editing.
    static func defaultSource(configs: [ConfigWorkspace],
                              openConfigID: ConfigWorkspace.ID?) -> BarRenderSource? {
        if let openConfigID, configs.contains(where: { $0.id == openConfigID }) {
            return .config(openConfigID)
        }
        return configs.first.map { .config($0.id) }
    }
}

/// The picker of the preview pane.
///
/// It names the config or the profile the bar is rendered from, the display
/// the bar is rendered for and the width of that display. The width is the
/// width of the display that is picked, unless the user overrides it.
struct BarRenderProfilePicker: View {
    @ObservedObject var store: SketchyBarStore
    let theme: AppTheme
    /// The width the user typed, as it was typed.
    ///
    /// The text is kept, so a width with a fraction is not rounded under
    /// the caret of the user.
    @State private var widthText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("Config", selection: sourceBinding) {
                    ForEach(choices) { choice in
                        Text(choice.menuTitle).tag(choice.source)
                    }
                }
                .frame(maxWidth: 320)
                .help("The config or the profile the bar is rendered from.")

                Spacer()
            }

            HStack(spacing: 8) {
                Picker("Display", selection: displayBinding) {
                    ForEach(displays) { display in
                        Text("\(display.name) - \(Int(display.widthPoints)) points").tag(display.id)
                    }
                }
                .frame(maxWidth: 320)
                .help("The display the bar is rendered for. The bar takes the width of that display.")

                Spacer()

                Text("Width")
                    .font(.caption)
                    .foregroundStyle(theme.muted)

                TextField("Width", text: widthBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .help("The width of the display the bar is rendered for, in points. Empty uses the width of the display that is picked.")

                if store.barRenderWidthOverride != nil {
                    Button("Use Display Width") {
                        store.barRenderWidthOverride = nil
                        widthText = ""
                    }
                    .buttonStyle(.link)
                    .help("Use the width of the display that is picked again.")
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                if let detail = currentChoice?.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if !usesDrafts {
                    Text("This is shown as it is on disk. Only the config the app has open shows the unsaved drafts.")
                        .font(.caption)
                        .foregroundStyle(theme.muted)
                }

                if let width = store.barRenderWidthOverride {
                    Text(widthNote(for: width))
                        .font(.caption)
                        .foregroundStyle(theme.muted)
                }
            }
        }
        .onAppear {
            widthText = store.barRenderWidthOverride.map { String($0) } ?? ""
        }
    }

    private var choices: [BarRenderChoice] {
        BarRenderChoices.make(configs: store.configs,
                              profiles: store.libraryProfiles,
                              openConfigID: store.selectedConfig?.id)
    }

    /// The displays of the machine.
    private var displays: [BarRenderDisplay] {
        BarRenderDisplays.all()
    }

    /// The source the pane renders.
    private var effectiveSource: BarRenderSource? {
        if let source = store.barRenderSource { return source }
        return BarRenderChoices.defaultSource(configs: store.configs,
                                              openConfigID: store.selectedConfig?.id)
    }

    /// True when the render shows the drafts of the app.
    private var usesDrafts: Bool {
        guard case .config(let id) = effectiveSource else { return false }
        return id == store.selectedConfig?.id
    }

    /// The choice the picker shows.
    private var currentChoice: BarRenderChoice? {
        guard let source = effectiveSource else { return nil }
        return choices.first { $0.source == source }
    }

    /// The note about the width the render uses.
    ///
    /// The width of the display is the width of the virtual display, so
    /// the bar has the proportions of the real menu bar of that display:
    /// a SketchyBar bar is the display width minus twice the margin
    /// (`src/bar.c:437-494`).
    private func widthNote(for width: Double) -> String {
        var note = "The bar is rendered for a width of \(width) points, and not for the width of the display."
        if width >= BarRendererService.maximumDisplayWidthPoints {
            note += " The width is limited to \(Int(BarRendererService.maximumDisplayWidthPoints)) points, so the render does not ask for a bitmap the machine cannot hold."
        }
        return note
    }

    private var sourceBinding: Binding<BarRenderSource> {
        Binding(
            get: { effectiveSource ?? .config("") },
            set: { store.barRenderSource = $0 }
        )
    }

    /// The display the bar is rendered for.
    ///
    /// The default is the display the app is on, so the picker names the
    /// display it uses.
    private var displayBinding: Binding<String> {
        Binding(
            get: {
                store.barRenderDisplayID
                    ?? BarRenderDisplays.main()?.id
                    ?? displays.first?.id
                    ?? ""
            },
            set: { store.barRenderDisplayID = $0 }
        )
    }

    /// The width the user typed.
    ///
    /// A width that is not a number is ignored, so the last width the
    /// render used stays. A width that is too big is limited, because the
    /// bitmap of the bar is the width of the display times the scale of
    /// 2.0, and a bitmap that is too big cannot be drawn.
    private var widthBinding: Binding<String> {
        Binding(
            get: { widthText },
            set: { text in
                widthText = text
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    store.barRenderWidthOverride = nil
                    return
                }
                guard let width = Double(trimmed), width.isFinite else { return }
                store.barRenderWidthOverride = min(max(width, 1),
                                                  BarRendererService.maximumDisplayWidthPoints)
            }
        )
    }
}
