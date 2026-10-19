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
                .accessibilityLabel("Source code editor")
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
        let scrollView = SourceScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.setAccessibilityLabel("Source code editor")

        let textView = VimTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 12 + LineNumberGutterView.width, height: 12)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.setAccessibilityLabel("Source code editor")
        textView.onModeChange = { mode in
            context.coordinator.mode.wrappedValue = mode
        }

        let gutter = LineNumberGutterView()
        gutter.textView = textView
        textView.gutter = gutter
        textView.addSubview(gutter)
        gutter.refresh()

        scrollView.documentView = textView
        scrollView.onScroll = { [weak scrollView, weak textView] in
            guard let scrollView, let textView else { return }
            textView.gutter?.horizontalOffset = scrollView.contentView.bounds.origin.x
        }
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
        textView.gutter?.refresh()
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
            (textView as? VimTextView)?.gutter?.refresh()
        }
    }
}

/// A scroll view that reports when the source scrolls sideways.
private final class SourceScrollView: NSScrollView {
    var onScroll: (() -> Void)?

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        onScroll?()
    }
}

/// The line numbers next to the source text.
private final class LineNumberGutterView: NSView {
    static let width: CGFloat = 46

    weak var textView: NSTextView?
    private var lineStarts: [Int] = [0]

    /// The horizontal scroll of the text, so the numbers stay at the left.
    var horizontalOffset: CGFloat = 0 {
        didSet {
            guard horizontalOffset != oldValue else { return }
            frame.origin.x = horizontalOffset
            needsDisplay = true
        }
    }

    func refresh() {
        guard let textView else { return }
        lineStarts = LineNumberGutterView.lineStarts(of: textView.string)
        let height = max(textView.bounds.height, 1)
        if frame.size != NSSize(width: Self.width, height: height) {
            frame.size = NSSize(width: Self.width, height: height)
        }
        needsDisplay = true
    }

    /// The gutter sits in the margin, so clicks belong to the text.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let origin = textView.textContainerOrigin
        // The gutter counts from the bottom, the text view from the top.
        let topDown = NSRect(
            x: 0,
            y: bounds.height - dirtyRect.maxY,
            width: dirtyRect.width,
            height: dirtyRect.height
        )
        guard topDown.height > 0 else { return }
        // The text starts at the container origin, so the visible strip is
        // looked up over the whole width of the text.
        let containerRect = NSRect(
            x: 0,
            y: topDown.minY - origin.y,
            width: max(textView.bounds.width, 1000),
            height: topDown.height
        )
        let glyphRange = layoutManager.glyphRange(forBoundingRect: containerRect, in: textContainer)
        var actualRange = NSRange()
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: &actualRange)

        var index = lineIndex(atOrBefore: charRange.location)
        while index < lineStarts.count {
            let start = lineStarts[index]
            guard start < charRange.upperBound else { break }
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: start)
            var effectiveRange = NSRange()
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &effectiveRange)
            let lineTop = fragment.minY + origin.y
            let lineBottom = bounds.height - (lineTop + fragment.height)
            draw(lineNumber: index + 1, bottom: lineBottom, height: fragment.height)
            index += 1
        }
    }

    private func draw(lineNumber: Int, bottom: CGFloat, height: CGFloat) {
        let label = "\(lineNumber)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: LineNumberGutterView.rightAligned
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(
            in: NSRect(
                x: 0,
                y: bottom + (height - size.height) / 2,
                width: bounds.width - 10,
                height: size.height
            ),
            withAttributes: attributes
        )
    }

    /// The index of the line that holds the given character.
    private func lineIndex(atOrBefore location: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= location {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }

    private static func lineStarts(of string: String) -> [Int] {
        var starts = [0]
        for (offset, codeUnit) in string.utf16.enumerated() where codeUnit == 0x0A {
            starts.append(offset + 1)
        }
        return starts
    }

    private static let rightAligned: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        return style
    }()
}

private final class VimTextView: NSTextView {
    var vimMotionsEnabled = false
    var mode: VimMode = .insert {
        didSet { isEditable = !vimMotionsEnabled || mode == .insert }
    }
    var onModeChange: ((VimMode) -> Void)?
    weak var gutter: LineNumberGutterView?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        gutter?.refresh()
    }

    override func layout() {
        super.layout()
        gutter?.refresh()
    }

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
