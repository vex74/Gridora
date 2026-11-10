import SwiftUI

/// Deterministic description of the inline glass preview. `Settings` is the
/// only input, and the view below renders exactly these values; the probe uses
/// the same struct so it can never pass on a second, hand-written formula.
struct GlassPreviewSnapshot: Equatable {
    let enabled: Bool
    let style: SearchGlassStyle
    let tintPercent: Int
    let radius: Int
    let scrimPercent: Int

    init(settings: Settings) {
        enabled = settings.searchGlassEnabled
        style = settings.searchGlassStyle
        tintPercent = Int((settings.searchGlassTint * 100).rounded())
        radius = Int(settings.searchGlassRadius.rounded())
        scrimPercent = Int((settings.searchScrim * 100).rounded())
    }

    var modeText: String { enabled ? "液态玻璃" : "近黑实底" }

    var readout: String {
        "\(style.label) · 着色 \(tintPercent)% · 圆角 \(radius)pt · 压暗 \(scrimPercent)%"
    }
}

/// Inline preview for Settings ▸ Appearance. The settings panel covers the real
/// search surface, so without this the four glass sliders had no visible
/// effect until settings were closed. Both capsules go through the very same
/// `SearchGlassPanel` modifier as the live search field and results panel.
struct GlassPreviewStage: View {
    @EnvironmentObject var model: LauncherModel

    private var snapshot: GlassPreviewSnapshot {
        GlassPreviewSnapshot(settings: model.settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("实时预览")
                    .font(.system(size: DesignTokens.caption, weight: .medium))
                    .foregroundStyle(DesignTokens.settingsMuted)
                Spacer()
                Text(snapshot.modeText)
                    .font(.system(size: DesignTokens.micro, weight: .medium))
                    .foregroundStyle(DesignTokens.settingsAccent)
            }

            stage
                .frame(height: 112)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardRadius,
                                            style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.cardRadius,
                                          style: .continuous)
                    .stroke(DesignTokens.settingsHairline, lineWidth: DesignTokens.hairline))
                .allowsHitTesting(false)

            Text(snapshot.readout)
                .font(.system(size: DesignTokens.caption).monospacedDigit())
                .foregroundStyle(DesignTokens.settingsMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("搜索外观实时预览：\(snapshot.modeText)，\(snapshot.readout)")
    }

    private var stage: some View {
        let radius = CGFloat(model.settings.searchGlassRadius)
        return ZStack {
            DesignTokens.canvas
            RadialGradient(colors: [DesignTokens.auroraCoolA.opacity(0.55), .clear],
                           center: .topLeading, startRadius: 20, endRadius: 420)
            // Mirrors the live scrim: glass thins the opaque layer, so the
            // preview shows the same relative darkening as search does.
            Color.black.opacity(model.settings.searchScrim
                                * (model.settings.searchGlassEnabled ? 0.45 : 1.0))

            VStack(spacing: 9) {
                fieldPreview(radius: radius)
                resultPreview(radius: radius)
            }
            .padding(.horizontal, 22)
        }
    }

    private func fieldPreview(radius: CGFloat) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text("搜索 App")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
            Spacer()
            Text("3")
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .modifier(SearchGlassPanel(settings: model.settings, fallback: .solidField))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(DesignTokens.signal.opacity(0.75), lineWidth: 1)
        }
    }

    private func resultPreview(radius: CGFloat) -> some View {
        HStack(spacing: 9) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.white.opacity(0.16 + Double(i) * 0.04))
                    .frame(width: 22, height: 22)
            }
            Text("搜索结果")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            Text("⏎")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .modifier(SearchGlassPanel(settings: model.settings))
    }
}

// MARK: - Folder panel preview

/// Deterministic description of the folder preview. `Settings` is the only
/// input, so `--appearance-probe` can assert that every one of the five new
/// sliders really reaches the rendered surface instead of trusting a copy of
/// the formula.
struct FolderGlassSnapshot: Equatable {
    let enabled: Bool
    let style: SearchGlassStyle
    let tintPercent: Int
    let radius: Int
    let scrimPercent: Int

    init(settings: Settings) {
        enabled = settings.folderGlassEnabled
        style = settings.folderGlassStyle
        tintPercent = Int((settings.folderGlassTint * 100).rounded())
        radius = Int(settings.folderGlassRadius.rounded())
        scrimPercent = Int((settings.folderGlassScrim * 100).rounded())
    }

    var modeText: String { enabled ? "液态玻璃" : "近黑实底" }

    var readout: String {
        "\(style.label) · 着色 \(tintPercent)% · 圆角 \(radius)pt · 压暗 \(scrimPercent)%"
    }
}

/// Inline preview for Settings ▸ Appearance ▸ 文件夹. The settings pane covers
/// the real folder, so this miniature panel goes through the identical
/// `FolderGlassPanel` modifier as the live folder overlay.
struct FolderGlassPreviewStage: View {
    @EnvironmentObject var model: LauncherModel

    private var snapshot: FolderGlassSnapshot {
        FolderGlassSnapshot(settings: model.settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("实时预览")
                    .font(.system(size: DesignTokens.caption, weight: .medium))
                    .foregroundStyle(DesignTokens.settingsMuted)
                Spacer()
                Text(snapshot.modeText)
                    .font(.system(size: DesignTokens.micro, weight: .medium))
                    .foregroundStyle(DesignTokens.settingsAccent)
            }

            stage
                .frame(height: 176)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardRadius,
                                            style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.cardRadius,
                                          style: .continuous)
                    .stroke(DesignTokens.settingsHairline, lineWidth: DesignTokens.hairline))
                .allowsHitTesting(false)

            Text(snapshot.readout)
                .font(.system(size: DesignTokens.caption).monospacedDigit())
                .foregroundStyle(DesignTokens.settingsMuted)
                .fixedSize(horizontal: false, vertical: true)
            Text(iconGlass.readout)
                .font(.system(size: DesignTokens.caption).monospacedDigit())
                .foregroundStyle(DesignTokens.settingsMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("文件夹外观实时预览：\(snapshot.modeText)，\(snapshot.readout)；"
                            + "网格小图标 \(iconGlass.modeText)，\(iconGlass.readout)")
    }

    /// The collapsed tile uses the very same mapping as the grid; showing it
    /// beside the open panel makes "同步" visible while a slider moves.
    private var iconGlass: FolderIconGlass {
        FolderIconGlass(settings: model.settings, size: 46)
    }

    private var stage: some View {
        VStack(spacing: 8) {
            ZStack {
                DesignTokens.canvas
                RadialGradient(colors: [DesignTokens.auroraCoolA.opacity(0.55), .clear],
                               center: .topLeading, startRadius: 20, endRadius: 420)
                // Mirrors the live sheet: glass needs less opaque dimming behind it.
                Color.black.opacity(model.settings.folderGlassScrim
                                    * (model.settings.folderGlassEnabled ? 0.45 : 1.0))
                folderPanel.frame(width: 208)
            }
            HStack(spacing: 10) {
                smallIconPreview
                VStack(alignment: .leading, spacing: 2) {
                    Text("网格中的文件夹小图标")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                    Text("与面板共用同一组参数")
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private var smallIconPreview: some View {
        let g = iconGlass
        let shape = RoundedRectangle(cornerRadius: g.enabled ? g.cornerRadius : 46 * 0.235,
                                     style: .continuous)
        return ZStack {
            if g.enabled {
                FolderIconGlassSurface(glass: g)
            } else {
                shape
                    .fill(.white.opacity(0.13))
                    .background(.ultraThinMaterial, in: shape)
                    .overlay { shape.stroke(.white.opacity(0.18), lineWidth: 0.8) }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(11), spacing: 3), count: 3),
                      spacing: 3) {
                ForEach(0..<6, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(.white.opacity(0.24 + Double(i) * 0.05))
                        .frame(width: 11, height: 11)
                }
            }
            .padding(4)
        }
        .frame(width: 46, height: 46)
    }

    private var folderPanel: some View {
        VStack(spacing: 0) {
            // Same header as the real panel: close button, folder name, and
            // nothing else. No app count, no pencil — the name is the rename
            // control. The clear filler keeps the title centred.
            HStack(spacing: 6) {
                previewButton("xmark")
                Spacer(minLength: 4)
                Text("文件夹")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 4)
                Color.clear.frame(width: 14, height: 14)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider().overlay(.white.opacity(0.08))

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 16), count: 3),
                      spacing: 10) {
                ForEach(0..<5, id: \.self) { i in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.white.opacity(0.18 + Double(i) * 0.05))
                            .frame(width: 24, height: 24)
                        Text("App")
                            .font(.system(size: 6))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
            .padding(.vertical, 12)

            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(.white.opacity(i == 0 ? 0.9 : 0.28))
                        .frame(width: 4, height: 4)
                }
            }
            .padding(.bottom, 10)
        }
        .modifier(FolderGlassPanel(settings: model.settings))
    }

    private func previewButton(_ name: String) -> some View {
        Circle()
            .fill(.white.opacity(0.10))
            .frame(width: 14, height: 14)
            .overlay {
                Image(systemName: name)
                    .font(.system(size: 6, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
            }
    }
}
