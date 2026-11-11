import AppKit
import SwiftUI

struct HiddenAppsOverlay: View {
    @EnvironmentObject var model: LauncherModel

    private var listHeight: CGFloat {
        let rows = max(1, Int(ceil(Double(model.hiddenTiles.count) / 6.0)))
        return min(CGFloat(rows) * 98 + 40, 340)
    }

    var body: some View {
        ZStack {
            // v1.6.4: no hand-rolled scrim. The hidden-apps overlay uses the
            // SAME fog surface as folder / search, so the top strip and the
            // grid stay one composite (and one source of dimming).
            BackdropFogSurface(
                fog: BackdropFog.make(
                    settings: model.settings,
                    state: BackdropFog.state(
                        openFolderID: model.openFolderID,
                        searchOpen: model.searchOpen,
                        outsidePanel: false,
                        hiddenOpen: model.hiddenOpen)),
                onClose: { model.hiddenOpen = false })

            VStack(spacing: 0) {
                header
                Divider().overlay(.white.opacity(0.08))

                if model.hiddenTiles.isEmpty {
                    emptyState
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                            ForEach(model.hiddenTiles) { tile in
                                HiddenAppCell(tile: tile)
                            }
                        }
                        .padding(20)
                    }
                    .frame(height: listHeight)
                }

                footer
            }
            .frame(width: 660)
            .background(PanelBackground(cornerRadius: DesignTokens.panelRadius))
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("已隐藏的 App")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                Text("点击图标即可恢复到启动台")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.35))
            }
            Spacer()
            Text("\(model.hiddenTiles.count) 个")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.42))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(.white.opacity(0.07)))
            GlassIconButton(systemName: "xmark") {
                model.hiddenOpen = false
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "eye.slash")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.white.opacity(0.28))
            Text("还没有隐藏任何 App")
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.45))
            Text("在图标上右键 → 隐藏，或在设置里开启「自动隐藏不常用 App」")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.28))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("被隐藏的 App 不会出现在网格和搜索中")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.30))
            Spacer()
            Button {
                model.restoreAllHidden()
            } label: {
                Text("全部恢复")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(model.hiddenTiles.isEmpty ? 0.3 : 0.9))
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .disabled(model.hiddenTiles.isEmpty)
        }
        .padding(.horizontal, 22)
        .frame(height: 54)
        .background(.white.opacity(0.035))
        .overlay(alignment: .top) {
            Divider().overlay(.white.opacity(0.07))
        }
    }
}

struct HiddenAppCell: View {
    @EnvironmentObject var model: LauncherModel
    let tile: Tile

    @State private var hover = false

    private var title: String {
        if let folder = tile.folder { return folder.name }
        if let id = tile.bundleID { return model.appsByID[id]?.name ?? "" }
        return ""
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if hover {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.white.opacity(0.10))
                        .frame(width: 66, height: 66)
                }
                TileIcon(tile: tile, size: 52)
                    .opacity(hover ? 0.55 : 1)
                if hover {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(color: .black.opacity(0.4), radius: 4)
                }
            }
            .frame(width: 70, height: 70)

            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 92)
        }
        .frame(maxWidth: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hover = $0 }
        .onTapGesture {
            withAnimation(Motion.reorder) { model.unhide(tileID: tile.id) }
        }
        .help("恢复到启动台")
    }
}
