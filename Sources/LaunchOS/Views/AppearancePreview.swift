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
