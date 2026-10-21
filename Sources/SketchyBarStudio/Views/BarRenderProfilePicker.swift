import SwiftUI

/// One choice of the preview picker: a config of the library or a saved
/// profile of the config the app has open.
struct BarRenderChoice: Identifiable, Hashable {
    let source: BarRenderSource
    /// The name of the config or of the profile.
    let title: String
    /// Where it lives, for the user.
    let detail: String
    /// True when the choice is the config the app has open, so the render
    /// shows the unsaved drafts.
    let isOpen: Bool

    var id: String { source.id }
}

/// The choices of the preview picker.
enum BarRenderChoices {
    /// Every config of the library and every saved profile of the config
    /// the app has open.
    static func make(configs: [ConfigWorkspace],
                     profiles: [ConfigProfile],
                     openConfigID: ConfigWorkspace.ID?) -> [BarRenderChoice] {
        var choices = configs.map { config in
            BarRenderChoice(source: .config(config.id),
                            title: config.name,
                            detail: config.path,
                            isOpen: config.id == openConfigID)
        }

        let owner = configs.first { $0.id == openConfigID }?.name ?? "the config"
        choices += profiles.map { profile in
            BarRenderChoice(source: .profile(profilePath: profile.id),
                            title: profile.name,
                            detail: "Saved profile of \(owner)",
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
/// width of the display of the machine, unless the user overrides it.
struct BarRenderProfilePicker: View {
    @ObservedObject var store: SketchyBarStore
    let theme: AppTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("Config", selection: sourceBinding) {
                    ForEach(choices) { choice in
                        Text(choice.title).tag(choice.source)
                    }
                }
                .frame(maxWidth: 320)
                .help("The config or the profile the bar is rendered from.")

                Spacer()
            }

            HStack(spacing: 8) {
                Label(displayText, systemImage: "display")
                    .font(.caption)
                    .foregroundStyle(theme.muted)

                Spacer()

                Text("Width")
                    .font(.caption)
                    .foregroundStyle(theme.muted)

                TextField("Width", text: widthBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .help("The width of the display the bar is rendered for, in points. Empty uses the width of the display of the machine.")

                if store.barRenderWidthOverride != nil {
                    Button("Use Display Width") {
                        store.barRenderWidthOverride = nil
                    }
                    .buttonStyle(.link)
                    .help("Use the width of the display of the machine again.")
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
                    Text("This config is shown as it is on disk. Only the config the app has open shows the unsaved drafts.")
                        .font(.caption)
                        .foregroundStyle(theme.muted)
                }
            }
        }
    }

    private var choices: [BarRenderChoice] {
        BarRenderChoices.make(configs: store.configs,
                              profiles: store.profiles,
                              openConfigID: store.selectedConfig?.id)
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

    /// The display the bar is rendered for, with the width that is used.
    private var displayText: String {
        let display = BarRenderDisplay.target()
        let name = BarRenderDisplay.name(of: display)
        let width = store.barRenderWidthOverride ?? BarRenderDisplay.width(of: display)
        let note = store.barRenderWidthOverride == nil ? "" : " (overridden)"
        return "Display: \(name) - \(Int(width.rounded())) points\(note)"
    }

    private var sourceBinding: Binding<BarRenderSource> {
        Binding(
            get: { effectiveSource ?? .config("") },
            set: { store.barRenderSource = $0 }
        )
    }

    private var widthBinding: Binding<String> {
        Binding(
            get: { store.barRenderWidthOverride.map { String(Int($0.rounded())) } ?? "" },
            set: { text in
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    store.barRenderWidthOverride = nil
                    return
                }
                guard let width = Double(trimmed), width > 0 else { return }
                store.barRenderWidthOverride = width
            }
        )
    }
}
