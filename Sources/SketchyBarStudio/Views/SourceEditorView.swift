import AppKit
import SwiftUI

struct SourceEditorView: View {
    @ObservedObject var store: SketchyBarStore
    let file: ConfigFile
    let theme: AppTheme
    @AppStorage("sourceEditor.vimMotions") private var vimMotionsEnabled = false
    @State private var vimMode: VimMode = .insert

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Source Editor", systemImage: "document.badge.gearshape")
                    .font(.headline)
                    .foregroundStyle(theme.accent)

                Text(file.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Toggle("Vim motions", isOn: $vimMotionsEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Use h/j/k/l, w/b, 0/$, i/a, and Escape")

                if vimMotionsEnabled {
                    Text(vimMode.rawValue)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(vimMode == .insert ? theme.syntaxString : theme.accent)
                }

                Button("Revert") {
                    store.discardSourceChanges(for: file)
                }
                .disabled(!store.sourceHasUnsavedChanges(for: file))

                Button("Save Source") {
                    store.saveRawContents(for: file)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!store.sourceHasUnsavedChanges(for: file))
            }

            if !store.canEditSource(for: file) {
                ContentUnavailableView(
                    "Control Edits Are Unsaved",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Save or discard the control edits before editing this file's complete source.")
                )
                .frame(minHeight: 420)
            } else if let error = store.sourceLoadError(for: file) {
                ContentUnavailableView(
                    "Source Could Not Be Loaded",
                    systemImage: "doc.badge.ellipsis",
                    description: Text(error)
                )
                .frame(minHeight: 420)
            } else {
                VimTextEditor(
                    text: sourceBinding,
                    vimMotionsEnabled: vimMotionsEnabled,
                    mode: $vimMode,
                    theme: theme
                )
                .frame(minHeight: 420)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(24)
        .onAppear(perform: prepareContents)
        .onChange(of: file.id) { _, _ in
            prepareContents()
        }
    }

    private var sourceBinding: Binding<String> {
        Binding(
            get: { store.sourceContents(for: file) },
            set: { store.updateSourceContents($0, for: file) }
        )
    }

    private func prepareContents() {
        store.prepareSourceEditing(for: file)
        vimMode = vimMotionsEnabled ? .normal : .insert
    }
}

enum VimMode: String {
    case normal = "NORMAL"
    case insert = "INSERT"
}

private struct VimTextEditor: NSViewRepresentable {
    @Binding var text: String
    let vimMotionsEnabled: Bool
    @Binding var mode: VimMode
    let theme: AppTheme

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, mode: $mode)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        let textView = VimTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.onModeChange = { mode in
            context.coordinator.mode.wrappedValue = mode
        }
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? VimTextView else { return }
        context.coordinator.text = $text
        context.coordinator.mode = $mode
        if textView.string != text {
            textView.string = text
        }
        textView.vimMotionsEnabled = vimMotionsEnabled
        textView.mode = vimMotionsEnabled ? mode : .insert
        textView.backgroundColor = NSColor(theme.background)
        textView.textColor = NSColor(theme.syntaxVariable)
        textView.insertionPointColor = NSColor(theme.accent)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var mode: Binding<VimMode>

        init(text: Binding<String>, mode: Binding<VimMode>) {
            self.text = text
            self.mode = mode
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

private final class VimTextView: NSTextView {
    var vimMotionsEnabled = false
    var mode: VimMode = .insert {
        didSet { isEditable = !vimMotionsEnabled || mode == .insert }
    }
    var onModeChange: ((VimMode) -> Void)?

    override func keyDown(with event: NSEvent) {
        guard vimMotionsEnabled else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == 53 {
            setMode(.normal)
            return
        }

        let applicationShortcutModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .function]
        if !event.modifierFlags.intersection(applicationShortcutModifiers).isEmpty {
            super.keyDown(with: event)
            return
        }

        guard mode == .normal, let character = event.charactersIgnoringModifiers else {
            super.keyDown(with: event)
            return
        }

        switch character {
        case "i": setMode(.insert)
        case "a":
            moveRight(nil)
            setMode(.insert)
        case "h": moveLeft(nil)
        case "j": moveDown(nil)
        case "k": moveUp(nil)
        case "l": moveRight(nil)
        case "w": moveWordForward(nil)
        case "b": moveWordBackward(nil)
        case "0": moveToBeginningOfLine(nil)
        case "$": moveToEndOfLine(nil)
        default: NSSound.beep()
        }
    }

    private func setMode(_ mode: VimMode) {
        self.mode = mode
        onModeChange?(mode)
    }
}
