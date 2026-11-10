import AppKit
import SwiftUI

/// macOS 15 Launchpad-style folder: a large centred panel, a 3 × 3 page of
/// full-size icons, and — critically — an app can be dragged back out onto the
/// grid. The panel stays in the view tree while a drag is in flight (it only
/// fades), otherwise SwiftUI would cancel the gesture the moment the folder
/// closed underneath the user's hand.
struct FolderOverlay: View {
    @EnvironmentObject var model: LauncherModel
    @EnvironmentObject var folderDragInfo: FolderDragInfo
    let folderID: String
    let folder: Folder

    @State private var nameDraft = ""
    @State private var pageIndex = 0
    @State private var panelFrame: CGRect = .zero
    @FocusState private var nameFocused: Bool

    private let columns = 3
    private let perPage = 9

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

    private var cellWidth: CGFloat { (panelWidth - 88) / CGFloat(columns) }
    private var cellHeight: CGFloat { iconSize + 54 }
    private var gridHeight: CGFloat { 3 * cellHeight + 2 * 18 + 40 }

    private var chunks: [[AppInfo]] {
        stride(from: 0, to: apps.count, by: perPage).map { start in
            Array(apps[start..<min(start + perPage, apps.count)])
        }
    }

    var body: some View {
        GeometryReader { window in
            ZStack {
                Color.black.opacity(folderDragInfo.outsidePanel ? 0.10 : 0.46)
                    .ignoresSafeArea()
                    .onTapGesture { close() }

                VStack(spacing: 0) {
                    header
                    Divider().overlay(.white.opacity(0.08))

                    if apps.isEmpty {
                        Text("文件夹是空的")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(width: panelWidth, height: gridHeight)
                    } else {
                        folderGrid
                        if chunks.count > 1 { pageBar }
                    }
                }
                .frame(width: panelWidth)
                .background(PanelBackground(cornerRadius: DesignTokens.panelRadius))
                .background(
                    GeometryReader { panel in
                        // A plain onAppear write, not a PreferenceKey: the
                        // folder panel only needs its frame once, and a
                        // preference that re-evaluates during paging damages
                        // the pager's rasterised-page cache.
                        Color.clear.onAppear { panelFrame = panel.frame(in: .global) }
                    }
                )
                .opacity(folderDragInfo.outsidePanel ? 0.06 : 1)
                .animation(Motion.quick, value: folderDragInfo.outsidePanel)

                if let appID = folderDragInfo.appID, let app = model.appsByID[appID] {
                    FolderDragVisual(app: app,
                                     size: iconSize,
                                     windowFrame: window.frame(in: .global))
                }
            }
            .onAppear { nameDraft = folder.name }
            .onChange(of: folderID) { _, _ in
                nameDraft = folder.name
                pageIndex = 0
            }
        }
    }

    // MARK: - Grid

    private var folderGrid: some View {
        let visible = chunks.indices.contains(pageIndex) ? chunks[pageIndex] : []
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(cellWidth), spacing: 12),
                                        count: columns),
                         spacing: 18) {
            ForEach(visible) { app in
                FolderAppCell(app: app,
                              folderID: folderID,
                              size: iconSize,
                              cellWidth: cellWidth,
                              cellHeight: cellHeight)
                    .gesture(
                        DragGesture(minimumDistance: 6, coordinateSpace: .global)
                            .onChanged { value in
                                if folderDragInfo.appID == nil {
                                    model.beginFolderDrag(appID: app.bundleID,
                                                          folderID: folderID,
                                                          at: value.location)
                                }
                                model.updateFolderDrag(to: value.location,
                                                       panelFrame: panelFrame)
                            }
                            .onEnded { value in
                                _ = model.endFolderDrag(at: value.location,
                                                        panelFrame: panelFrame)
                            }
                    )
            }
            if visible.count < perPage {
                ForEach(0..<(perPage - visible.count), id: \.self) { _ in
                    Color.clear.frame(height: cellHeight)
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 20)
        .frame(height: gridHeight)
    }

    private var pageBar: some View {
        HStack(spacing: 16) {
            Button {
                withAnimation(Motion.quick) { pageIndex = max(0, pageIndex - 1) }
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
                    Capsule()
                        .fill(.white.opacity(index == pageIndex ? 0.9 : 0.28))
                        .frame(width: index == pageIndex ? 18 : 6, height: 6)
                }
            }

            Button {
                withAnimation(Motion.quick) {
                    pageIndex = min(chunks.count - 1, pageIndex + 1)
                }
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
    let size: CGFloat
    let cellWidth: CGFloat
    let cellHeight: CGFloat

    @State private var hover = false

    var body: some View {
        VStack(spacing: 9) {
            ZStack {
                if hover {
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .fill(.white.opacity(0.10))
                        .frame(width: size * 1.16, height: size * 1.16)
                }
                AppIconImage(app: app, size: size)
            }
            .frame(width: size + 20, height: size + 20)

            Text(app.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.84))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: cellWidth - 12)
        }
        .frame(width: cellWidth, height: cellHeight)
        .opacity(folderDragInfo.appID == app.bundleID ? 0.22 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { hover = $0 }
        .onTapGesture {
            model.openFolderID = nil
            model.launch(app)
        }
        .contextMenu {
            Button("打开") { model.openFolderID = nil; model.launch(app) }
            Button("在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([app.url])
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
