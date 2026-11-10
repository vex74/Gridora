import AppKit
import SwiftUI

struct TileView: View {
    @EnvironmentObject var model: LauncherModel
    /// Low-frequency companions: these publish on page crossings and merge
    /// target changes, never on pointer movement or per-frame scrolling.
    @EnvironmentObject var pageState: PageState
    @EnvironmentObject var dragInfo: DragSemanticState

    let tile: Tile
    let index: Int
    let page: Int
    let metrics: GridMetrics

    @State private var hover = false

    private var isSource: Bool { dragInfo.value.sourceID == tile.id }

    private var app: AppInfo? {
        guard let id = tile.bundleID else { return nil }
        return model.appsByID[id]
    }

    private var title: String {
        tile.folder?.name ?? app?.name ?? "未知"
    }

    private var isSelected: Bool {
        model.selection == index && pageState.index == page && !dragInfo.value.active
    }

    private var isMergeTarget: Bool {
        dragInfo.value.targetID == tile.id
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if hover && !dragInfo.value.active {
                    RoundedRectangle(cornerRadius: metrics.iconSize * 0.30, style: .continuous)
                        .fill(.white.opacity(0.13))
                        .frame(width: metrics.iconSize * 1.20, height: metrics.iconSize * 1.20)
                        .blur(radius: 18)
                }

                TileIcon(tile: tile, size: metrics.iconSize)
                    .scaleEffect(isMergeTarget ? 1.10 : (hover ? 1.035 : 1))
                    .animation(Motion.quick, value: hover)
                    .animation(Motion.reorder, value: isMergeTarget)
            }
            .frame(width: metrics.iconSize + 18, height: metrics.iconSize + 18)
            .overlay {
                if isMergeTarget {
                    RoundedRectangle(cornerRadius: metrics.iconSize * 0.27, style: .continuous)
                        .stroke(.white.opacity(0.9), lineWidth: 2)
                        .shadow(color: .white.opacity(0.35), radius: 8)
                } else if isSelected {
                    RoundedRectangle(cornerRadius: metrics.iconSize * 0.27, style: .continuous)
                        .stroke(.white.opacity(0.82), lineWidth: 2.5)
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                }
            }
            .overlay {
                if model.flashID == tile.id {
                    RoundedRectangle(cornerRadius: metrics.iconSize * 0.27, style: .continuous)
                        .stroke(.white.opacity(0.75), lineWidth: 2)
                        .scaleEffect(1.14)
                        .opacity(0.0)
                        // Scoped to this tile: a launch used to open an
                        // animation transaction on every tile in the grid.
                        .animation(.easeOut(duration: 0.5), value: model.flashID == tile.id)
                }
            }

            if model.settings.showLabels {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(isSelected ? 0.98 : 0.86))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(.white.opacity(0.16))
                        }
                    }
                    .shadow(color: .black.opacity(0.55), radius: 3, x: 0, y: 1)
                    .frame(width: max(metrics.cellW - 10, 40))
            }
        }
        .frame(width: metrics.cellW, height: metrics.cellH)
        .opacity(isSource ? 0 : 1)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                let center = CGPoint(x: metrics.cellW / 2,
                                     y: metrics.cellH / 2 + iconOffsetY)
                let half = metrics.iconHitHalf - 1
                let inside = abs(location.x - center.x) <= half && abs(location.y - center.y) <= half
                if hover != inside {
                    withAnimation(Motion.quick) { hover = inside }
                }
                // Hover is purely local @State now. Publishing it on the
                // global model used to invalidate every tile in the grid each
                // time the cursor crossed an icon while scrolling.
            case .ended:
                if hover { withAnimation(Motion.quick) { hover = false } }
            }
        }
        .contextMenu { contextMenu }
        .help(title)
        // VoiceOver sees one labelled button per tile instead of a pile of
        // unlabelled images and text. These are static modifiers: they do not
        // subscribe to the paging offset, so the rasterised pages stay stable.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.isFolder ? "文件夹，\(title)" : title)
        .accessibilityHint(tile.isFolder ? "打开文件夹" : "打开 App")
        .accessibilityAddTraits(.isButton)
    }

    private var iconOffsetY: CGFloat {
        guard model.settings.showLabels else { return 0 }
        return -(6 + 19) / 2
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button(tile.isFolder ? "打开文件夹" : "打开") {
            model.activate(tile)
        }

        if let app {
            Button("在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([app.url])
            }
        }

        Divider()

        Button("移到上一页") {
            model.moveTile(tileID: tile.id, toPage: page - 1)
        }
        .disabled(page == 0)

        Button("移到下一页") {
            model.moveTile(tileID: tile.id, toPage: page + 1)
        }
        .disabled(page >= model.pageCount - 1)

        Divider()

        if tile.isFolder {
            Button("重命名文件夹") {
                model.renamingFolderID = tile.id
                model.openFolderID = tile.id
            }
            Button("解散文件夹") {
                model.dissolveFolder(id: tile.id)
            }
        }

        Button("隐藏") {
            model.hide(tileID: tile.id)
        }
    }
}
