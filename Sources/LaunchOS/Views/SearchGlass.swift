import AppKit
import SwiftUI

/// Single source of truth that maps the one global glass group onto real
/// Liquid Glass inputs. The deployment target is macOS 14, so every macOS 26
/// symbol lives behind an availability check and older systems get a material
/// + dark tint instead of an empty / unreadable surface.
enum SearchGlass {
    static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// The search field and results panel derive their corner radius from the
    /// single global `glassRadius` — the one number that describes the largest
    /// surface (the folder panel). 58% of it, clamped to 8…20 pt, so the
    /// default 24 pt panel radius yields the 14 pt the field has always had.
    /// One slider, consistent rounding on every surface, no second knob.
    static func fieldRadius(_ panelRadius: Double) -> CGFloat {
        min(max(CGFloat(panelRadius) * 0.58, 8), 20)
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
        let radius = SearchGlass.fieldRadius(settings.glassRadius)
        if #available(macOS 26.0, *), settings.glassEnabled {
            content.glassEffect(
                SearchGlass.configuration(style: settings.glassStyle,
                                          tint: settings.glassTint,
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
        } else if settings.glassEnabled {
            // Glass requested but the OS cannot provide it: keep a readable
            // material panel rather than silently dropping the feature.
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color.black.opacity(0.35 + settings.glassTint * 0.5))
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
                                                          tint: settings.glassScrim,
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

/// The open-folder panel. It renders through the very same
/// `SearchGlass.configuration` as the search surfaces and, since v1.5, reads
/// the very same five global glass values — one parameter set for every glass
/// surface in the app.
///
/// Three explicit states, all testable:
/// • macOS 26+ and enabled → real `glassEffect` (CABackdropLayer).
/// • older macOS and enabled → ultra-thin material + dark tint, so the white
///   folder labels stay readable instead of landing on a transparent view.
/// • disabled → the original `PanelBackground` near-black solid panel.
///
/// The hairline stroke is shared with `PanelBackground`; the soft shadow only
/// exists on the glass path so the panel still separates from the wallpaper.
struct FolderGlassPanel: ViewModifier {
    let settings: Settings

    func body(content: Content) -> some View {
        let radius = CGFloat(settings.glassRadius)
        if #available(macOS 26.0, *), settings.glassEnabled {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            content
                .glassEffect(SearchGlass.configuration(style: settings.glassStyle,
                                                       tint: settings.glassTint,
                                                       interactive: true),
                             in: shape)
                .overlay { shape.stroke(.white.opacity(0.16), lineWidth: 0.8) }
                .shadow(color: .black.opacity(0.35), radius: 32, y: 18)
        } else {
            content.background { fallbackSurface(radius: radius) }
        }
    }

    @ViewBuilder
    private func fallbackSurface(radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if settings.glassEnabled {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color.black.opacity(0.35 + settings.glassTint * 0.5))
            }
            .overlay { shape.stroke(.white.opacity(0.16), lineWidth: 0.8) }
        } else {
            PanelBackground(cornerRadius: radius)
        }
    }
}

// MARK: - Collapsed folder icon in the grid

struct FolderGlassPlateProvidedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True only inside a PageSlot that already drew the glass plates in its
    /// background (outside the raster). Everywhere else — drag visual, hidden
    /// apps sheet, settings tile previews — the collapsed folder icon draws
    /// its own standalone glass so it never turns into a transparent hole.
    var folderGlassPlateProvided: Bool {
        get { self[FolderGlassPlateProvidedKey.self] }
        set { self[FolderGlassPlateProvidedKey.self] = newValue }
    }
}

/// The small folder tile shares the exact same five global `glass*` values as
/// the open-folder panel and the search surfaces, so one slider moves every
/// glass surface. It is rendered inside `PageSlot.drawingGroup()` (the
/// rasterised paging path), therefore the mapping is a pure value: no
/// observation, no `.interactive()` glass, and no backdrop sampling of the
/// whole screen. `LAUNCHOS_FOLDER_ICON_NOGLASS=1` is the rollback switch used
/// by the measured A/B.
struct FolderIconGlass: Equatable {
    let enabled: Bool
    let style: SearchGlassStyle
    let tint: Double
    let tintPercent: Int
    let radius: Int
    let scrimPercent: Int
    let cornerRadius: CGFloat
    let innerDim: Double
    let size: CGFloat

    init(settings: Settings, size: CGFloat) {
        self.size = size
        // A standalone glassEffect inside the rasterised page is both invisible
        // and expensive (measured 9.75% jank / 17.98ms p95). With plates
        // disabled the icon therefore goes straight back to its old material
        // instead of attempting glass in the wrong place.
        enabled = settings.glassEnabled
            && !ProbeConfig.folderIconNoGlass
            && (ProbeConfig.folderIconPlate || ProbeConfig.noRaster)
        style = settings.glassStyle
        tint = settings.glassTint
        tintPercent = Int((settings.glassTint * 100).rounded())
        radius = Int(settings.glassRadius.rounded())
        scrimPercent = Int((settings.glassScrim * 100).rounded())
        // The 6–36pt panel radius describes a ~600pt surface; scale it onto a
        // ~80pt icon and clamp so the tile never becomes a circle or a square.
        // The default value reproduces the original 0.235 ratio exactly.
        let base = size * 0.235
        let factor = CGFloat(settings.glassRadius / Settings.defaultGlassRadius)
        cornerRadius = min(max(base * factor, size * 0.10), size * 0.42)
        // The shared "背板压暗" becomes the icon's inner dimming, so the same
        // slider still does something visible on a surface with no backdrop.
        innerDim = settings.glassScrim * 0.5
    }

    var modeText: String { enabled ? "液态玻璃" : "原材质" }

    var readout: String {
        "\(style.label) · 着色 \(tintPercent)% · 圆角 \(radius)pt"
            + " · 压暗 \(scrimPercent)% · 图标圆角 \(Int(cornerRadius.rounded()))pt"
    }
}

/// Glass backing for the collapsed folder icon. Non-interactive glass is
/// deliberate: an `.interactive()` layer per folder tile would put a
/// hover-reactive backdrop into every rasterised page.
struct FolderIconGlassSurface: View {
    let glass: FolderIconGlass

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: glass.cornerRadius,
                                     style: .continuous)
        ZStack {
            if #available(macOS 26.0, *) {
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .glassEffect(SearchGlass.configuration(style: glass.style,
                                                           tint: glass.tint,
                                                           interactive: false),
                                 in: shape)
            } else {
                // Older systems: a readable material instead of an empty tile.
                shape.fill(.ultraThinMaterial)
            }
            shape.fill(Color.black.opacity(glass.innerDim))
            shape.stroke(.white.opacity(0.20), lineWidth: 0.8)
        }
        .clipShape(shape)
        .frame(width: glass.size, height: glass.size)
        .allowsHitTesting(false)
    }
}
