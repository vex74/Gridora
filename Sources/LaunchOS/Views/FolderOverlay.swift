import AppKit
import SwiftUI

/// macOS 15 Launchpad-style folder: a large centred panel, a 3 × 3 page of
/// full-size icons, and — critically — an app can be dragged back out onto the
/// grid. The panel stays in the view tree while a drag is in flight (it only
/// fades), otherwise SwiftUI would cancel the gesture the moment the folder
/// closed underneath the user's hand.
///
/// `LauncherModel.folderPage` is the single source of truth for the visible
/// 3 × 3 page: the wheel, arrow keys, page dots, chevrons and diagnostics all
/// write it, so they can never disagree with what is drawn.
struct FolderOverlay: View {
    @EnvironmentObject var model: LauncherModel
    @EnvironmentObject var folderDragInfo: FolderDragInfo
    let folderID: String
    let folder: Folder

    @State private var nameDraft = ""
    @State private var panelFrame: CGRect = .zero
    /// `.global` frame of the padded 3 × 3 grid. Recorded once, like
    /// `panelFrame`: a PreferenceKey here would re-evaluate during paging and
    /// damage the rasterised page cache behind the panel.
    @State private var gridFrame: CGRect = .zero
    @State private var appeared = false
    /// Only the folder name itself turns into a rename target, so it needs a
    /// hover cue — otherwise nothing on screen says "click me".
    @State private var titleHover = false
    @FocusState private var nameFocused: Bool

    private var apps: [AppInfo] {
        folder.bundleIDs.compactMap { model.appsByID[$0] }
    }

    private var isRenaming: Bool { model.renamingFolderID == folderID }

    /// Folder icons used to be 62 pt inside a 430 pt panel — visibly smaller
    /// than the grid. Match the grid artwork instead.
    private var iconSize: CGFloat {
        min(max(model.metrics.iconSize * 0.92, 92), 128)
    }

    /// Single source: the model computes the panel width because the wheel
    /// uses it as the page extent for `PagingRules.flickThreshold`. Drawing
    /// and input must never disagree about how wide a folder page is.
    private var panelWidth: CGFloat { model.folderPanelWidth }

    /// The one geometry object shared by drawing, click hit-testing and drop
    /// targets. Nothing in this file re-derives cell arithmetic.
    private var grid: FolderGridMetrics {
        FolderGridMetrics(cellWidth: (panelWidth - 88) / 3,
                          cellHeight: iconSize + 54,
                          iconSize: iconSize)
    }

    private var chunks: [[AppInfo]] {
        let per = FolderGridMetrics.perPage
        return stride(from: 0, to: apps.count, by: per).map { start in
            Array(apps[start..<min(start + per, apps.count)])
        }
    }

    private var pageIndex: Int {
        min(max(model.folderPage, 0), max(0, chunks.count - 1))
    }

    private var visible: [AppInfo] {
        chunks.indices.contains(pageIndex) ? chunks[pageIndex] : []
    }

    /// Reorder preview while an app is dragged *inside* the panel. The same
    /// remove-then-insert the model performs on release, so the icons make way
    /// exactly where the app will land. Only `dropSlot` (a cell index) is
    /// published; the 120 Hz pointer stream never touches this array.
    private var displayed: [AppInfo] {
        guard let drop = folderDragInfo.dropSlot,
              let draggingID = folderDragInfo.appID,
              let source = visible.firstIndex(where: { $0.bundleID == draggingID }),
              source != drop else { return visible }
        var result = visible
        let moved = result.remove(at: source)
        result.insert(moved, at: min(max(drop, 0), result.count))
        return result
    }

    var body: some View {
        GeometryReader { window in
            ZStack {
                // One full-screen fog, shared with the menu-bar cover window
                // (level 26) and with search. Before v1.6.1 this was a local
                // ultraThinMaterial + scrim, so the top strip — a separate
                // NSWindow — kept the clean wallpaper and a seam appeared.
                // The main window is the only one that closes on a click.
                BackdropFogSurface(
                    fog: BackdropFog.make(
                        settings: model.settings,
                        state: .folder(outsidePanel: folderDragInfo.outsidePanel),
                        plate: model.fogPlate),
                    coversGrid: true,
                    onClose: { close() })

                VStack(spacing: 0) {
                    header
                    Divider().overlay(.white.opacity(0.08))

                    if apps.isEmpty {
                        Text("文件夹是空的")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(width: panelWidth, height: grid.gridHeight)
                    } else {
                        pageStrip
                        if chunks.count > 1 { pageBar }
                    }
                }
                .frame(width: panelWidth)
                // One modifier owns all three surface states (system glass,
                // material fallback, original near-black solid). The folder
                // overlay is outside the paging subtree, so no glass layer
                // ever enters the rasterised page cache.
                .modifier(FolderGlassPanel(settings: model.settings))
                .background(
                    GeometryReader { panel in
                        // A plain onAppear write, not a PreferenceKey: the
                        // folder panel only needs its frame once.
                        Color.clear.onAppear { panelFrame = panel.frame(in: .global) }
                    }
                )
                // Grow out of the clicked folder tile, then rest slightly
                // above centre — both are macOS 15 Launchpad behaviours.
                .offset(y: -26)
                .scaleEffect(appeared ? 1 : 0.86, anchor: openAnchor(in: window.size))
                .opacity(appeared ? 1 : 0)
                .opacity(folderDragInfo.outsidePanel ? 0.06 : 1)
                .animation(Motion.quick, value: folderDragInfo.outsidePanel)

                if let appID = folderDragInfo.appID, let app = model.appsByID[appID] {
                    FolderDragVisual(app: app,
                                     size: iconSize,
                                     windowFrame: window.frame(in: .global))
                }
            }
            .onAppear {
                nameDraft = folder.name
                withAnimation(Motion.panel) { appeared = true }
            }
            .onChange(of: folderID) { _, _ in
                nameDraft = folder.name
                model.setFolderPage(0)
            }
        }
    }

    // MARK: - Grid

    /// The 3 × 3 pages side by side, slid horizontally. macOS 15 turns a
    /// folder page with the same movement as the main Launchpad pages, so the
    /// panel no longer swaps its contents in place: the strip translates by
    /// exactly one page width and `Motion.page` is the pager's critically
    /// damped curve. Both pagers now share `PagingRules` for input and
    /// `Motion.page` for the animation, which is what "one paging model"
    /// means here — the folder just clips instead of rubber-banding.
    private var pageStrip: some View {
        let g = grid
        return HStack(spacing: 0) {
            ForEach(chunks.indices, id: \.self) { page in
                pageColumn(page, grid: g)
            }
        }
        .offset(x: -CGFloat(pageIndex) * g.gridWidth)
        .frame(width: g.gridWidth, height: g.gridHeight, alignment: .topLeading)
        .clipped()
        .animation(Motion.page, value: pageIndex)
        .background(
            GeometryReader { gridGeo in
                Color.clear.onAppear { gridFrame = gridGeo.frame(in: .global) }
            }
        )
    }

    /// The apps shown on a given page: the live reorder preview applies only
    /// to the page the user is on, every other page keeps its committed order.
    private func pageItems(_ page: Int) -> [AppInfo] {
        guard chunks.indices.contains(page) else { return [] }
        return page == pageIndex ? displayed : chunks[page]
    }

    private func pageColumn(_ page: Int, grid g: FolderGridMetrics) -> some View {
        let items = pageItems(page)
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(g.cellWidth),
                                                           spacing: g.columnSpacing),
                                        count: FolderGridMetrics.columns),
                         spacing: g.rowSpacing) {
            ForEach(Array(items.enumerated()), id: \.element.bundleID) { slot, app in
                FolderAppCell(app: app,
                              folderID: folderID,
                              grid: g,
                              slot: slot,
                              visibleCount: items.count)
                    .gesture(
                        DragGesture(minimumDistance: 6, coordinateSpace: .global)
                            .onChanged { value in
                                if folderDragInfo.appID == nil {
                                    model.beginFolderDrag(appID: app.bundleID,
                                                          folderID: folderID,
                                                          at: value.location)
                                }
                                model.updateFolderDrag(to: value.location,
                                                       panelFrame: panelFrame,
                                                       gridFrame: gridFrame,
                                                       grid: g)
                            }
                            .onEnded { value in
                                _ = model.endFolderDrag(at: value.location,
                                                        panelFrame: panelFrame,
                                                        gridFrame: gridFrame,
                                                        grid: g)
                            }
                    )
            }
            if items.count < FolderGridMetrics.perPage {
                ForEach(0..<(FolderGridMetrics.perPage - items.count), id: \.self) { _ in
                    Color.clear.frame(height: g.cellHeight)
                }
            }
        }
        .padding(.horizontal, g.horizontalPadding)
        .padding(.vertical, g.verticalPadding)
        .frame(width: g.gridWidth, height: g.gridHeight, alignment: .top)
        .animation(Motion.quick, value: items.map(\.bundleID))
    }

    /// Dots only — no chevrons. macOS 15 has never put arrow buttons on a
    /// folder; the wheel, the arrow keys and the dots are the paging controls.
    /// Same `PagingDots` component as the main grid, without its capsule
    /// chrome (the panel already is a surface).
    private var pageBar: some View {
        PagingDots(count: chunks.count, index: pageIndex, chrome: false) { page in
            model.setFolderPage(page)
        }
        .frame(height: 46)
        .padding(.bottom, 6)
    }

    // MARK: - Header

    /// macOS 15 keeps only two things up here: a close button and the folder
    /// name. No app count, no pencil — the name itself is the rename control
    /// (one click, not double click). The title sits in its own layer so it
    /// stays optically centred whether or not the right corner is occupied by
    /// the "完成" button during a rename.
    private var header: some View {
        ZStack {
            nameTitle

            HStack(spacing: 12) {
                GlassIconButton(systemName: "xmark") { close() }

                // Explicitly inert and explicitly non-hit-testing: a Spacer is
                // usually transparent to clicks but this keeps the rename tap
                // working no matter how SwiftUI resolves the ZStack order.
                // Fixed height on purpose — a flexible-height filler would let
                // the ZStack grow the header and stretch the whole panel.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .allowsHitTesting(false)

                if isRenaming {
                    Button("完成") { commitRename() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 40, height: 30)
                        .contentShape(Rectangle())
                } else {
                    // Same footprint as the close button. Without it the title
                    // drifts right by half a button; with it the folder name
                    // is dead centre exactly like macOS 15.
                    Color.clear
                        .frame(width: 30, height: 30)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var nameTitle: some View {
        if isRenaming {
            TextField("文件夹名称", text: $nameDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .focused($nameFocused)
                .frame(maxWidth: 300)
                .onSubmit { commitRename() }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        nameFocused = true
                    }
                }
        } else {
            Text(folder.name)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white.opacity(titleHover ? 1 : 0.95))
                .lineLimit(1)
                // Never let a long name run under the close / done buttons.
                .frame(maxWidth: panelWidth - 140)
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.white.opacity(titleHover ? 0.09 : 0))
                )
                .contentShape(Rectangle())
                .onHover { hovering in
                    if titleHover != hovering { titleHover = hovering }
                }
                .onTapGesture { beginRename() }
                .help("点击重命名文件夹")
                .animation(Motion.quick, value: titleHover)
        }
    }

    /// Launchpad grows a folder out of the tile that was clicked. The pager
    /// frame and this anchor are both in SwiftUI's `.global` space (origin at
    /// the window's top-left), so the ratio is a valid UnitPoint here. A
    /// missing/zero pager frame (cold start, probes) falls back to centre.
    private func openAnchor(in size: CGSize) -> UnitPoint {
        guard let p = model.folderOpenOrigin,
              size.width > 1, size.height > 1,
              model.pagerFrameInWindow.width > 1 else { return .center }
        let f = model.pagerFrameInWindow
        return UnitPoint(x: min(max((f.minX + p.x) / size.width, 0), 1),
                         y: min(max((f.minY + p.y) / size.height, 0), 1))
    }

    private func beginRename() {
        nameDraft = folder.name
        model.renamingFolderID = folderID
    }

    private func commitRename() {
        model.renameFolder(id: folderID, to: nameDraft)
        model.renamingFolderID = nil
        nameFocused = false
    }

    private func close() {
        if isRenaming { commitRename() }
        model.openFolderID = nil
    }
}

// MARK: - Cell inside the folder

struct FolderAppCell: View {
    @EnvironmentObject var model: LauncherModel
    @EnvironmentObject var folderDragInfo: FolderDragInfo
    let app: AppInfo
    let folderID: String
    let grid: FolderGridMetrics
    let slot: Int
    /// Number of apps actually shown on this folder page. `hoverIndex` uses
    /// it so trailing empty slots never light up, exactly like `iconIndex`.
    let visibleCount: Int

    @State private var hover = false

    private var highlight: SelectionHighlightStyle {
        SelectionHighlightStyle(settings: model.settings, iconSize: grid.iconSize)
    }

    private var otherFolders: [Folder] {
        model.allFolders.filter { $0.id != folderID }
    }

    /// Artwork square in the cell's own coordinates. `FolderGridMetrics` is
    /// the same object the hit-test probe uses, so "click the icon" means the
    /// same rectangle in the panel and in the diagnostic.
    private var iconRect: CGRect {
        grid.artworkLocalRect(at: slot)
    }

    var body: some View {
        let art = iconRect
        return ZStack(alignment: .topLeading) {
            // Only this artwork square carries the tap gesture AND the hover
            // highlight. The label, cell corners and row/column gaps are
            // inert, matching the main grid's iconIndex(at:count:) rule.
            ZStack {
                SelectionHighlightSurface(style: highlight,
                                          state: hover ? .hover : .none)
                AppIconImage(app: app, size: grid.iconSize)
            }
            .frame(width: art.width, height: art.height)
            .contentShape(Rectangle())
            .onTapGesture {
                model.openFolderID = nil
                model.launch(app)
            }
            .position(x: art.midX, y: art.midY)

            Text(app.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.84))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: grid.cellWidth - 12, height: 16)
                .position(x: grid.cellWidth / 2, y: art.maxY + 9 + 8)
        }
        .frame(width: grid.cellWidth, height: grid.cellHeight)
        .opacity(folderDragInfo.appID == app.bundleID ? 0.22 : 1)
        // NO `.contentShape(Rectangle())` and NO plain `.onHover` here. The
        // v1.4 fix moved the tap onto the artwork but left both of these on
        // the whole cell, so pointing at the label or a cell corner still lit
        // the selection highlight — "range selection" came back. Hover is now
        // gated by the SAME geometry the tap and the probe use; removing the
        // whole-cell contentShape also stops it from widening the child's tap.
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                let inside = grid.hoverIndex(atLocal: location, slot: slot,
                                             count: visibleCount) == slot
                if hover != inside { withAnimation(Motion.quick) { hover = inside } }
            case .ended:
                if hover { withAnimation(Motion.quick) { hover = false } }
            }
        }
        .contextMenu {
            Button("打开") { model.openFolderID = nil; model.launch(app) }
            Button("在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([app.url])
            }
            Divider()
            Menu("移动到其他文件夹") {
                ForEach(otherFolders) { folder in
                    Button {
                        model.moveAppIntoFolder(appID: app.bundleID, folderID: folder.id)
                    } label: {
                        Text("\(folder.name) · \(folder.bundleIDs.count) 个 App")
                    }
                }
                if otherFolders.isEmpty {
                    Text("没有其他文件夹")
                }
            }
            Divider()
            Button("从文件夹移出") {
                model.removeFromFolder(appID: app.bundleID, folderID: folderID)
            }
            Button("隐藏") {
                model.removeFromFolder(appID: app.bundleID, folderID: folderID)
                model.hide(tileID: app.bundleID)
            }
        }
    }
}

// MARK: - Floating icon while dragging out

/// Only this view subscribes to the 120 Hz pointer position.
struct FolderDragVisual: View {
    @EnvironmentObject var folderDragMotion: FolderDragMotion
    let app: AppInfo
    let size: CGFloat
    let windowFrame: CGRect

    var body: some View {
        let point = CGPoint(x: folderDragMotion.position.x - windowFrame.minX,
                            y: folderDragMotion.position.y - windowFrame.minY)
        return VStack(spacing: 8) {
            AppIconImage(app: app, size: size)
                .shadow(color: .black.opacity(0.55), radius: 20, y: 12)
            Text(app.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
        }
        .scaleEffect(1.08)
        .position(point)
        .allowsHitTesting(false)
        .zIndex(30)
    }
}
