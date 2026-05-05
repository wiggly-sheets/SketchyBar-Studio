import AppKit

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
        selectedFont = sender.convert(selectedFont)
        let nextValue = SketchyBarFont.value(from: selectedFont, for: keyPath, currentValue: currentValue)
        currentValue = nextValue
        onChange?(nextValue)
    }
}
