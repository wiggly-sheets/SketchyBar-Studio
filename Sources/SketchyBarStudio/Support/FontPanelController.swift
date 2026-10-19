import AppKit

@MainActor
final class FontPanelController: NSObject {
    static let shared = FontPanelController()

    private var selectedFont = NSFont.systemFont(ofSize: 14)
    private var keyPath = ""
    private var currentValue = ""
    private var onChange: ((String) -> Void)?

    func showFontPanel(keyPath: String, currentValue: String, onChange: @escaping (String) -> Void) {
        selectedFont = SketchyBarFont.initialFont(from: currentValue, keyPath: keyPath)
        self.keyPath = keyPath
        self.currentValue = currentValue
        self.onChange = onChange

        let manager = NSFontManager.shared
        manager.setSelectedFont(selectedFont, isMultiple: false)
        manager.target = self
        manager.action = #selector(changeFont(_:))
        manager.orderFrontFontPanel(nil)
    }

    @objc private func changeFont(_ sender: NSFontManager) {
        let candidate = sender.selectedFont ?? sender.convert(selectedFont)
        let family = candidate.familyName ?? ""
        let leaf = keyPath.lowercased().split(separator: ".").last.map(String.init) ?? keyPath.lowercased()

        // The panel sends an action for every keystroke in the family field,
        // so a half typed name must not be written to the config.
        if leaf == "font" || leaf == "family" {
            guard !family.isEmpty, NSFontManager.shared.availableFontFamilies.contains(family) else { return }
        }

        let nextValue = SketchyBarFont.value(from: candidate, for: keyPath, currentValue: currentValue)
        guard nextValue != currentValue else { return }

        selectedFont = candidate
        currentValue = nextValue
        onChange?(nextValue)
    }
}
