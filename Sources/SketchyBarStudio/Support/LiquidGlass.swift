import SwiftUI

extension View {
    /// Draws the view on Liquid Glass on macOS 26 and later. Earlier systems
    /// get the fallback fill, which is the flat surface the app used before.
    @ViewBuilder
    func liquidGlassSurface(
        cornerRadius: CGFloat = 12,
        tint: Color? = nil,
        interactive: Bool = false,
        fallback: Color = .clear
    ) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(
                Glass.regular.tint(tint).interactive(interactive),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            background(fallback, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    /// Uses the native glass button on macOS 26 and later. Earlier systems
    /// keep the style the call site already uses.
    @ViewBuilder
    func liquidGlassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            self
        }
    }
}

/// Merges nearby glass surfaces into one piece of glass on macOS 26 and
/// later. Earlier systems lay the content out unchanged.
struct LiquidGlassContainer<Content: View>: View {
    let spacing: CGFloat
    let content: () -> Content

    init(spacing: CGFloat = 8, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

/// The footer of a sheet: the actions sit on their own glass, grouped so
/// nearby buttons merge into one piece of glass.
struct GlassActionBar<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        HStack {
            Spacer()
            LiquidGlassContainer(spacing: 10) {
                HStack(spacing: 10) {
                    content()
                }
            }
        }
        .padding()
    }
}
