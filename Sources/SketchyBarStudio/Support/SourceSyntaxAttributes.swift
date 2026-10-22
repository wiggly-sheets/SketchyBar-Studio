import AppKit
import SwiftUI

/// The colours of the syntax tokens.
///
/// The editor uses these attributes and the preview uses the same mapping as
/// SwiftUI colours, so both views read the palette of the theme.
enum SourceSyntaxAttributes {
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    static func base(theme: AppTheme) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor(theme.syntaxVariable)
        ]
    }

    static func attributes(for kind: SourceTokenKind, theme: AppTheme) -> [NSAttributedString.Key: Any] {
        [.foregroundColor: color(for: kind, theme: theme)]
    }

    static func color(for kind: SourceTokenKind, theme: AppTheme) -> NSColor {
        switch kind {
        case .keyword, .flag:
            return NSColor(theme.accent)
        case .type:
            return NSColor(theme.syntaxString)
        case .string:
            return NSColor(theme.syntaxString)
        case .comment:
            return NSColor(theme.muted)
        case .number:
            return NSColor(theme.syntaxNumber)
        case .variable, .plain:
            return NSColor(theme.syntaxVariable)
        case .operator:
            return NSColor(theme.muted)
        }
    }
}

extension SourceTokenKind {
    /// The colour of the token in the SwiftUI preview.
    func color(in theme: AppTheme) -> Color {
        switch self {
        case .keyword, .flag:
            return theme.accent
        case .comment:
            return theme.muted
        case .string:
            return theme.syntaxString
        case .number:
            return theme.syntaxNumber
        case .variable:
            return theme.syntaxVariable
        case .type, .operator, .plain:
            return .primary
        }
    }
}
