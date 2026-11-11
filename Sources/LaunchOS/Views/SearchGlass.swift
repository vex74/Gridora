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

// MARK: - Full-screen backdrop fog (one source for both windows)

/// Which overlay owns the full-screen fog right now. The folder and search
/// states have different dimming (dragging out of a folder thins it to 10%),
/// but both must be described by the same value in BOTH windows.
enum BackdropFogState: Equatable {
    case none
    case folder(outsidePanel: Bool)
    case search
}

enum BackdropFogMaterial: String, Equatable {
    case none
    /// Pre-macOS-26 (or rollback): the original ultra-thin material.
    case material
    /// macOS 26+ real Liquid Glass, identical to search's old fog.
    case glass
}

/// v1.6.2. The menu-bar cover window (level 26) has NO grid underneath: its
/// Liquid Glass samples only the blurred wallpaper. The main window's fog sits
/// above every app icon, so the very same glass sampled those icons too —
/// coloured blobs beside an open folder and a hard brightness seam below the
/// top strip. This is the pure-value recipe for ONE extra, ICON-FREE copy of
/// that backdrop, painted under the main window's fog so both windows sample
/// identical pixels. It reuses wallpaper / backgroundBlur / backgroundDim; it
/// is not a sixth glass setting and adds no slider.
struct FogPlate: Equatable {
    let useWallpaper: Bool
    let wallpaper: NSImage?
    let blur: CGFloat
    let dim: Double

    static func == (lhs: FogPlate, rhs: FogPlate) -> Bool {
        lhs.useWallpaper == rhs.useWallpaper
            && lhs.wallpaper === rhs.wallpaper
            && lhs.blur == rhs.blur
            && lhs.dim == rhs.dim
    }
}

/// Pure value. The main window and the menu-bar cover are two different
/// NSWindows (levels 19 and 26). Before v1.6.1 the main window drew
/// `ultraThinMaterial` + a black scrim while the cover drew only the clean
/// blurred wallpaper, producing a visible seam across the top of the screen.
/// Every call site now constructs the SAME fog from the SAME five `glass*`
/// settings, so tint, material and dimming cannot drift apart. v1.6.2 adds
/// the shared `plate` recipe (only the MAIN window renders it).
struct BackdropFog: Equatable {
    let active: Bool
    /// Black dimming (and the click-catching layer in the main window).
    let scrim: Double
    /// Tint handed to the Liquid Glass fog.
    let tint: Double
    let material: BackdropFogMaterial
    /// Non-nil only while an open folder should hide the grid. `nil` during a
    /// drag-out, search, closed state or when the rollback switch is set.
    let plate: FogPlate?

    /// State mapping shared by the menu-bar cover and the diagnostics, so a
    /// probe tests the real view's decision rather than a look-alike copy.
    static func state(openFolderID: String?, searchOpen: Bool,
                      outsidePanel: Bool) -> BackdropFogState {
        if openFolderID != nil { return .folder(outsidePanel: outsidePanel) }
        if searchOpen { return .search }
        return .none
    }

    static func make(settings: Settings, state: BackdropFogState,
                     plate: FogPlate? = nil) -> BackdropFog {
        // Only the main window paints the plate (it is the one with a grid
        // underneath). A drag OUT of the folder must expose the grid again as
        // a drop target, so that state never carries a plate.
        let fogPlate: FogPlate?
        switch state {
        case .folder(let outside) where !outside:
            fogPlate = ProbeConfig.noFogPlate ? nil : plate
        default:
            fogPlate = nil
        }

        let scrim: Double
        let tint: Double
        switch state {
        case .none:
            return BackdropFog(active: false, scrim: 0, tint: 0,
                               material: .none, plate: nil)
        case .folder(let outside):
            // Dragging an app out of the panel thins the fog so the grid
            // underneath stays visible as a drop target.
            let base = outside ? 0.10 : settings.glassScrim
            scrim = base
            tint = base
        case .search:
            // Glass tints the backdrop by itself, so the opaque scrim is
            // thinned while glass is on. Same slider, no second knob.
            scrim = settings.glassEnabled
                ? settings.glassScrim * 0.45
                : settings.glassScrim
            tint = settings.glassScrim
        }

        let material: BackdropFogMaterial
        if !settings.glassEnabled {
            material = .none
        } else if SearchGlass.isAvailable && !ProbeConfig.noFogUnify {
            material = .glass
        } else {
            material = .material
        }
        return BackdropFog(active: true, scrim: scrim, tint: tint,
                           material: material, plate: fogPlate)
    }

    /// The cover window is the only call site that may opt out; the rollback
    /// intentionally restores the old unequal top strip.
    var visibleOnCover: Bool { active && !ProbeConfig.noFogUnify }

    var readout: String {
        "active=\(active) scrim=\(String(format: "%.4f", scrim)) "
            + "tint=\(String(format: "%.4f", tint)) "
            + "material=\(material.rawValue) cover=\(visibleOnCover) "
            + "plate=\(plate != nil ? 1 : 0)"
    }
}

/// The ONLY rendering exit for the full-screen fog. Three call sites:
/// `FolderOverlay` (main window), `SearchOverlay` (main window) and
/// `MenuBarCover` (separate window above the system menu bar). All three pass
/// a `BackdropFog`, so no view can hand-roll its own material or dimming.
///
/// The glass layer is always hit-test inert. Only the main window supplies
/// `onClose`, which makes the black scrim clickable to dismiss the panel;
/// the cover window is `ignoresMouseEvents` at the NSWindow level anyway.
struct BackdropFogSurface: View {
    let fog: BackdropFog
    /// Only the MAIN window has a grid underneath. The menu-bar cover already
    /// samples a clean wallpaper and must never paint a second copy.
    var coversGrid: Bool = false
    var onClose: (() -> Void)? = nil

    var body: some View {
        Group {
            if fog.active {
                ZStack {
                    if coversGrid, let plate = fog.plate {
                        FogPlateView(plate: plate)
                            .allowsHitTesting(false)
                    }
                    glassLayer
                        .allowsHitTesting(false)
                    Color.black.opacity(fog.scrim)
                        .onTapGesture { onClose?() }
                        // Last modifier wins: with no close action (the cover
                        // window) the whole scrim stays click-through.
                        .allowsHitTesting(onClose != nil)
                }
                .ignoresSafeArea()
                .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var glassLayer: some View {
        switch fog.material {
        case .none:
            EmptyView()
        case .material:
            Rectangle().fill(.ultraThinMaterial)
        case .glass:
            if #available(macOS 26.0, *) {
                Rectangle()
                    .fill(Color.black.opacity(0.001))
                    .glassEffect(SearchGlass.configuration(style: .clear,
                                                           tint: fog.tint,
                                                           interactive: false),
                                 in: Rectangle())
            }
        }
    }
}

/// Exactly the backdrop `MenuBarCover` draws, with the same `animate: false`.
/// Painting it under the main window's glass removes the grid from the glass
/// sample without touching the paging subtree or rebuilding a single tile.
/// `onAppear` is the view-layer evidence used by `--backdrop-fog-probe`: a
/// pure-value assertion alone would be a look-alike green.
private struct FogPlateView: View {
    let plate: FogPlate

    var body: some View {
        BackgroundView(useWallpaper: plate.useWallpaper,
                       wallpaper: plate.wallpaper,
                       blur: plate.blur,
                       dim: plate.dim,
                       animate: false)
            .onAppear { FogPlateRenderProbe.noteMain() }
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

// MARK: - Selection highlight (the fourth glass-driven surface)

/// The highlight shown when an app is hovered, keyboard-selected or hovered
/// as a merge target. Before v1.6 the main grid, search results and open
/// folder each hard-coded their own white rounded rectangle (radius 0.30 /
/// 0.25 / 0.24 × icon size, fill 0.13 / 0.10 / 0.10), so the global glass
/// sliders moved three surfaces but not the one the user points at most.
///
/// This is a PURE VALUE, not a `glassEffect`: the main grid lives inside
/// `PageSlot.drawingGroup()`, where real glass is both invisible and measured
/// at 9.75% jank / 17.98 ms p95. The five global glass values drive the
/// geometry and opacity instead, which is what "one parameter set, four
/// surfaces" can safely mean on the rasterised path.
struct SelectionHighlightStyle: Equatable {
    let enabled: Bool
    let isClear: Bool
    let iconSize: CGFloat
    let cornerRadius: CGFloat
    let hoverFill: Double
    let selectedFill: Double
    let strokeOpacity: Double
    let glowBlur: CGFloat
    let hoverScale: CGFloat
    let labelFill: Double

    init(settings: Settings, iconSize: CGFloat) {
        let useGlass = settings.glassEnabled && !ProbeConfig.selectionGlassDisabled
        enabled = useGlass
        isClear = useGlass && settings.glassStyle == .clear
        self.iconSize = iconSize

        // The 6–36 pt panel radius describes a ~600 pt surface. Scale the
        // main grid's original 0.27 × iconSize onto that range and clamp so
        // a tile never becomes a circle or a square. Default 24 pt lands
        // exactly back on 0.27.
        let factor = CGFloat(settings.glassRadius / Settings.defaultGlassRadius)
        cornerRadius = min(max(iconSize * 0.27 * factor, iconSize * 0.10),
                           iconSize * 0.42)

        // Tint 0.38 reproduces the three original values: 0.13 hover fill,
        // 0.82 selection stroke, 0.16 selected label background.
        let dim = isClear ? 0.62 : 1.0
        hoverFill = min(max((0.055 + settings.glassTint * 0.20) * dim, 0.05), 0.20)
        selectedFill = min(max((0.05 + settings.glassTint * 0.18) * dim, 0.04), 0.18)
        strokeOpacity = min(max((0.62 + settings.glassTint * 0.52) * dim, 0.60), 0.95)
        labelFill = min(max((0.08 + settings.glassTint * 0.21) * dim, 0.08), 0.22)
        glowBlur = useGlass ? min(max(iconSize * 0.20 * factor, 6), 26) : 0
        hoverScale = useGlass ? 1.035 : 1.0
    }

    /// One box for all three surfaces. The old code used +20 / +14 / +16;
    /// +18 is the main grid's value and sits between the other two.
    var boxSize: CGFloat { iconSize + 18 }

    func fillOpacity(for state: SelectionHighlightState) -> Double {
        switch state {
        case .none: return 0
        case .hover, .mergeTarget: return hoverFill
        case .selected: return selectedFill
        }
    }

    var readout: String {
        "半径 \(Int(cornerRadius.rounded()))pt · 悬停 \(Int((hoverFill * 100).rounded()))%"
            + " · 描边 \(Int((strokeOpacity * 100).rounded()))%"
            + " · 光晕 \(Int(glowBlur.rounded()))pt"
    }
}

enum SelectionHighlightState: Hashable, Equatable {
    case none
    case hover
    case selected
    case mergeTarget
}

/// One renderer for every app-selection cue. `accent` is optional so search
/// results can keep their signal-orange focus ring while the main grid and
/// the folder panel use white — shape, radius and opacity stay identical.
struct SelectionHighlightSurface: View {
    let style: SelectionHighlightStyle
    let state: SelectionHighlightState
    var accent: Color? = nil

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
    }

    var body: some View {
        Group {
            if state != .none {
                ZStack {
                    if state == .hover && style.glowBlur > 0 {
                        shape.fill(.white.opacity(style.hoverFill))
                            .frame(width: style.boxSize, height: style.boxSize)
                            .blur(radius: style.glowBlur)
                    }
                    shape.fill(.white.opacity(style.fillOpacity(for: state)))
                        .frame(width: style.boxSize, height: style.boxSize)

                    if state != .hover {
                        let color: Color = state == .mergeTarget
                            ? .white.opacity(0.9)
                            : (accent ?? .white.opacity(style.strokeOpacity))
                        shape.stroke(color,
                                     lineWidth: state == .mergeTarget ? 2 : 2.5)
                            .frame(width: style.boxSize, height: style.boxSize)
                            .shadow(color: .black.opacity(0.30), radius: 6, y: 2)
                    }
                }
                .frame(width: style.boxSize, height: style.boxSize)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
