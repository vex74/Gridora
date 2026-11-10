import AppKit
import SwiftUI

struct PagerView: View {
    @EnvironmentObject var model: LauncherModel
    /// Deliberately NOT an @ObservedObject. PagerView holds only a reference
    /// and hands it to PagingCanvas / DragLayer, which are the views that
    /// actually observe the offset. Otherwise the whole pager (geometry
    /// reader, gesture, drag layer) would re-evaluate on every vsync.
    let scroll: ScrollState

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if model.pages.allSatisfy({ $0.isEmpty }) && !model.isLoading {
                    EmptyGridMessage()
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }

                PagingCanvas(scroll: scroll,
                             size: geo.size,
                             pages: model.pages,
                             metrics: model.metrics,
                             vertical: model.settings.vertical,
                             glass: FolderIconGlass(settings: model.settings,
                                                    size: model.metrics.iconSize))

                // A separate view with its own observed objects. Pointer
                // movement re-evaluates this layer only — never PagerView, the
                // canvas, or any of the grid's tile bodies.
                DragLayer(scroll: scroll)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        model.pointerDragged(from: value.startLocation, to: value.location)
                    }
                    .onEnded { value in
                        model.pointerUp(at: value.location)
                    }
            )
            .onAppear {
                model.updateArea(geo.size)
                // Window-space frame of the pager lets a folder drop resolve
                // to an exact grid cell. Written once to a plain property:
                // A/B showed this costs nothing (median 2.3% vs 1.95% control,
                // p95 identical at 6.50 ms), while a PreferenceKey that
                // re-evaluated every paging frame was measurably worse.
                model.pagerFrameInWindow = geo.frame(in: .global)
            }
            .onChange(of: geo.size) { _, size in
                model.updateArea(size)
                model.pagerFrameInWindow = geo.frame(in: .global)
            }
        }
    }
}

// MARK: - Drag layer

/// The only view that re-evaluates on every mouse-moved event during a drag.
struct DragLayer: View {
    @EnvironmentObject var model: LauncherModel
    @EnvironmentObject var dragInfo: DragSemanticState
    @EnvironmentObject var dragMotion: DragMotionState
    @ObservedObject var scroll: ScrollState

    var body: some View {
        ZStack(alignment: .topLeading) {
            if dragInfo.value.active,
               let sourceID = dragInfo.value.sourceID,
               let tile = model.locate(sourceID)?.1 {
                let m = model.metrics
                let motion = dragMotion.value
                let center = CGPoint(x: motion.location.x + motion.grab.width,
                                     y: motion.location.y + motion.grab.height)

                if let slot = dragInfo.value.slot, let page = dragInfo.value.page {
                    // The merge highlight sits on the target's slot from the
                    // drag-start layout — exactly under the user's hand.
                    let pageOffset = CGSize(
                        width: model.settings.vertical ? 0
                            : CGFloat(page) * m.size.width - scroll.position,
                        height: model.settings.vertical
                            ? CGFloat(page) * m.size.height - scroll.position : 0)
                    let p = CGPoint(x: m.iconCenter(of: slot).x + pageOffset.width,
                                    y: m.iconCenter(of: slot).y + pageOffset.height)
                    RoundedRectangle(cornerRadius: m.iconSize * 0.3, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.95), lineWidth: 2.5)
                        .background(RoundedRectangle(cornerRadius: m.iconSize * 0.3, style: .continuous)
                            .fill(Color.white.opacity(0.14)))
                        .frame(width: m.iconSize + 16, height: m.iconSize + 16)
                        .position(p)
                }

                DraggedTileVisual(tile: tile, size: m.iconSize)
                    .rotationEffect(.degrees(Double(max(-7, min(7, motion.velocity * 0.25)))))
                    .scaleEffect(1.10)
                    .position(center)
            }
        }
        .allowsHitTesting(false)
        .zIndex(20)
    }
}

// MARK: - Paging canvas

/// The canvas itself does NOT observe the per-frame offset. It builds every
/// page once, as a plain value, and hands it to a tiny `PageSlot`. On each
/// vsync only those slots re-evaluate, so the 165 tile descriptions are never
/// re-created mid-flip. That stable value is what lets `drawingGroup()` really
/// cache a page: SwiftUI translates one rasterised layer instead of
/// re-compositing 55 tile trees every frame.
///
/// Measured with `--fps-probe` on a 3-page / 165-tile grid at 120 Hz: the old
/// canvas produced ~12% jank frames during paging; slots + rasterisation
/// produce ~2%, with p95 at the nominal 6.5 ms. Rasterisation alone only
/// reached ~5.5%, and slots alone were worse — the two are complementary.
struct PagingCanvas: View {
    let scroll: ScrollState
    let size: CGSize
    let pages: [[Tile]]
    let metrics: GridMetrics
    let vertical: Bool
    /// A plain value handed down from PagerView. The canvas does NOT observe
    /// settings or the offset; only PageSlot reads the offset.
    let glass: FolderIconGlass

    private var extent: CGFloat { vertical ? size.height : size.width }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(pages.indices, id: \.self) { page in
                PageSlot(scroll: scroll,
                         page: page,
                         span: extent,
                         size: size,
                         vertical: vertical,
                         folderFrames: Self.folderFrames(in: pages[page],
                                                         metrics: metrics),
                         glass: glass,
                         content: GridPage(page: page,
                                           tiles: pages[page],
                                           metrics: metrics))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// Reuses GridMetrics' one coordinate system — never re-derives cell
    /// arithmetic here (the merge bug was exactly that mistake).
    private static func folderFrames(in tiles: [Tile],
                                     metrics: GridMetrics) -> [FolderIconFrame] {
        tiles.enumerated().compactMap { index, tile in
            guard tile.isFolder else { return nil }
            return FolderIconFrame(id: tile.id,
                                   center: metrics.iconCenter(of: index))
        }
    }
}

struct FolderIconFrame: Identifiable {
    let id: String
    let center: CGPoint
}

/// Single-purpose leaf: read the offset, translate the page, nothing else.
/// Each page is permanently flattened into one raster layer. Toggling the
/// rasterisation only while scrolling was measured to be worse: every toggle
/// rebuilt the view tree and produced a 60–140 ms long frame, i.e. a visible
/// hitch at the start and end of every flip (p99 62 ms vs 15 ms).
///
/// Gestures, context menus, hover and accessibility keep working inside a
/// drawingGroup — Apple's WWDC21 "Add rich graphics to your SwiftUI app" uses
/// exactly that combination. Only standalone controls (TextField, List) are
/// unsuitable, and the grid has none. `LAUNCHOS_NO_RASTER=1` is a rollback
/// switch if any interaction ever regresses.
struct PageSlot<Content: View>: View {
    @ObservedObject var scroll: ScrollState
    let page: Int
    let span: CGFloat
    let size: CGSize
    let vertical: Bool
    let folderFrames: [FolderIconFrame]
    let glass: FolderIconGlass
    let content: Content

    var body: some View {
        let pos = scroll.position
        let distance = span > 1 ? abs(CGFloat(page) * span - pos) / span : 0
        let plated = glass.enabled && ProbeConfig.folderIconPlate && !ProbeConfig.noRaster
        Group {
            if ProbeConfig.noRaster {
                content.environment(\.folderGlassPlateProvided, false)
            } else {
                content.environment(\.folderGlassPlateProvided, plated).drawingGroup()
            }
        }
        // Real glass must sit OUTSIDE the raster: `glassEffect` inside
        // drawingGroup() produces zero CABackdropLayer / SDFPortalLayer. The
        // background modifier is applied after drawingGroup(), so these plates
        // keep the cached page layer intact while still sampling the wallpaper.
        // They carry no offset subscription — the whole group is translated by
        // the single .offset below, exactly as before.
        .background {
            if plated {
                ZStack(alignment: .topLeading) {
                    ForEach(folderFrames) { frame in
                        FolderIconGlassSurface(glass: glass)
                            .position(frame.center)
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
        .offset(x: vertical ? 0 : CGFloat(page) * span - pos,
                y: vertical ? CGFloat(page) * span - pos : 0)
        .allowsHitTesting(distance < 0.98)
    }
}

struct DraggedTileVisual: View {
    @EnvironmentObject var model: LauncherModel
    let tile: Tile
    let size: CGFloat

    private var title: String {
        tile.folder?.name ?? tile.bundleID.flatMap { model.appsByID[$0]?.name } ?? ""
    }

    var body: some View {
        VStack(spacing: 7) {
            // Outside a page, FolderIconView sees plateProvided == false and
            // draws its own standalone glass plate. No extra layer here.
            TileIcon(tile: tile, size: size)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .shadow(color: .black.opacity(0.6), radius: 4, y: 1)
        }
        .frame(width: size + 40)
        .shadow(color: .black.opacity(0.45), radius: 22, y: 14)
    }
}

// MARK: - One page of tiles

struct GridPage: View {
    let page: Int
    let tiles: [Tile]
    let metrics: GridMetrics

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                TileView(tile: tile,
                         index: index,
                         page: page,
                         metrics: metrics)
                    .position(metrics.center(of: index))
                    // No transition here. Pages are now built on demand as the
                    // ±1 window moves, so an insertion transition would fire
                    // on every page crossing and flash a scaled-in grid.
            }
        }
        .frame(width: metrics.size.width, height: metrics.size.height, alignment: .topLeading)
    }
}
