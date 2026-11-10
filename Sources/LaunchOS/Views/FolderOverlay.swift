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

    private var panelWidth: CGFloat {
        min(760, max(560, model.areaSize.width * 0.42))
    }

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
                // macOS 15 blurs the wallpaper and the grid behind an open
                // folder instead of laying a flat black sheet over them.
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                // The dimming behind the glass panel is user-adjustable now;
                // dragging out of the panel still thins it to 10% so the grid
                // underneath stays visible as a drop target.
                Color.black.opacity(folderDragInfo.outsidePanel
                                    ? 0.10 : model.settings.folderGlassScrim)
                    .ignoresSafeArea()
                    .onTapGesture { close() }

                VStack(spacing: 0) {
                    header
                    Divider().overlay(.white.opacity(0.08))

                    if apps.isEmpty {
                        Text("文件夹是空的")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(width: panelWidth, height: grid.gridHeight)
                    } else {
                        folderGrid
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

    private var folderGrid: some View {
        let g = grid
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(g.cellWidth), spacing: g.columnSpacing),
                                        count: FolderGridMetrics.columns),
                         spacing: g.rowSpacing) {
            ForEach(Array(displayed.enumerated()), id: \.element.bundleID) { slot, app in
                FolderAppCell(app: app,
                              folderID: folderID,
                              grid: g,
                              slot: slot)
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
            if displayed.count < FolderGridMetrics.perPage {
                ForEach(0..<(FolderGridMetrics.perPage - displayed.count), id: \.self) { _ in
                    Color.clear.frame(height: g.cellHeight)
                }
            }
        }
        .padding(.horizontal, g.horizontalPadding)
        .padding(.vertical, g.verticalPadding)
        .frame(height: g.gridHeight)
        .animation(Motion.quick, value: displayed.map(\.bundleID))
        .background(
            GeometryReader { gridGeo in
                Color.clear.onAppear { gridFrame = gridGeo.frame(in: .global) }
            }
        )
    }

    private var pageBar: some View {
        HStack(spacing: 16) {
            Button {
                withAnimation(Motion.quick) { model.turnFolderPage(-1) }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(pageIndex > 0 ? 0.8 : 0.22))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(pageIndex == 0)

            HStack(spacing: 7) {
                ForEach(chunks.indices, id: \.self) { index in
                    Circle()
                        .fill(.white.opacity(index == pageIndex ? 0.9 : 0.28))
                        .frame(width: 6, height: 6)
                        .frame(width: 18, height: 28)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(Motion.quick) { model.setFolderPage(index) }
                        }
                }
            }

            Button {
                withAnimation(Motion.quick) { model.turnFolderPage(1) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(pageIndex < chunks.count - 1 ? 0.8 : 0.22))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(pageIndex >= chunks.count - 1)
        }
        .frame(height: 46)
        .padding(.bottom, 6)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            GlassIconButton(systemName: "xmark") { close() }

            Spacer(minLength: 8)

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
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .onTapGesture(count: 2) { beginRename() }
            }

            Text("\(apps.count) 个 App")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.white.opacity(0.35))

            Spacer(minLength: 8)

            if isRenaming {
                Button("完成") { commitRename() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 40, height: 30)
            } else {
                GlassIconButton(systemName: "pencil", help: "重命名") { beginRename() }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
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

    @State private var hover = false

    private var otherFolders: [Folder] {
        model.allFolders.filter { $0.id != folderID }
    }

    /// Artwork square in the cell's own coordinates. `FolderGridMetrics` is
    /// the same object the hit-test probe uses, so "click the icon" means the
    /// same rectangle in the panel and in the diagnostic.
    private var iconRect: CGRect {
        let cell = grid.cellRect(at: slot)
        let art = grid.iconRect(at: slot)
        return CGRect(x: art.minX - cell.minX,
                      y: art.minY - cell.minY,
                      width: art.width,
                      height: art.height)
    }

    var body: some View {
        let art = iconRect
        return ZStack(alignment: .topLeading) {
            // Only this artwork square carries the tap gesture. The label,
            // cell corners and row/column gaps are inert, matching the main
            // grid's iconIndex(at:count:) rule.
            ZStack {
                if hover {
                    RoundedRectangle(cornerRadius: grid.iconSize * 0.24, style: .continuous)
                        .fill(.white.opacity(0.10))
                        .frame(width: grid.iconSize * 1.16,
                               height: grid.iconSize * 1.16)
                }
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
        .contentShape(Rectangle())
        .onHover { hover = $0 }
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
