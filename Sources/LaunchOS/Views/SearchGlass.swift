import AppKit
import SwiftUI

/// Single source of truth that maps the five `Settings` values onto real
/// Liquid Glass inputs. The deployment target is macOS 14, so every macOS 26
/// symbol lives behind an availability check and older systems get a material
/// + dark tint instead of an empty / unreadable surface.
enum SearchGlass {
    static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    @available(macOS 26.0, *)
    static func configuration(style: SearchGlassStyle,
                              tint: Double,
                              interactive: Bool) -> Glass {
        let base: Glass = style == .clear ? .clear : .regular
        let colored: Glass = tint > 0 ? base.tint(Color.black.opacity(tint)) : base
        return interactive ? colored.interactive() : colored
    }
}

/// What the surface should look like when Liquid Glass is off (or unavailable).
/// The field used to be an opaque near-black capsule; the results area used to
/// have no background at all, so the two call sites need different fallbacks.
enum SearchGlassFallback {
    case solidField
    case noPanel
}

struct SearchGlassPanel: ViewModifier {
    let settings: Settings
    var fallback: SearchGlassFallback = .noPanel

    func body(content: Content) -> some View {
        let radius = CGFloat(settings.searchGlassRadius)
        if #available(macOS 26.0, *), settings.searchGlassEnabled {
            content.glassEffect(
                SearchGlass.configuration(style: settings.searchGlassStyle,
                                          tint: settings.searchGlassTint,
                                          interactive: true),
                in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content.background { fallbackSurface(radius: radius) }
        }
    }

    @ViewBuilder
    private func fallbackSurface(radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if fallback == .solidField {
            shape.fill(DesignTokens.panelSurface.opacity(0.94))
        } else if settings.searchGlassEnabled {
            // Glass requested but the OS cannot provide it: keep a readable
            // material panel rather than silently dropping the feature.
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color.black.opacity(0.35 + settings.searchGlassTint * 0.5))
            }
        }
    }
}

/// Full-screen fog behind the search chrome. Sits above the click-catching
/// scrim and is explicitly hit-test disabled, so clicking empty space still
/// closes search exactly as before.
struct SearchGlassScrim: View {
    let settings: Settings

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                Rectangle()
                    .fill(Color.black.opacity(0.001))
                    .glassEffect(SearchGlass.configuration(style: .clear,
                                                          tint: settings.searchScrim,
                                                          interactive: false),
                                 in: Rectangle())
            } else {
                Rectangle().fill(.ultraThinMaterial)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
