import AppKit
import SwiftUI

/// Pure value inputs: the backdrop must never re-evaluate when the model's
/// interaction state (drag, selection, paging) changes.
struct BackgroundView: View {
    let useWallpaper: Bool
    let wallpaper: NSImage?
    let blur: CGFloat
    let dim: Double
    /// Ambient drift is stopped while the launcher is hidden so the app burns
    /// no GPU time in the background.
    let animate: Bool

    @State private var drift = false
    /// SwiftUI's environment value updates on its own when the system
    /// "Reduce motion" preference changes, so the slow ambient drift stops
    /// immediately without any manual notification plumbing.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Probe switches are compile-time-cheap runtime reads that are all false
    /// in a normal launch, so the shipped rendering path is unchanged.
    private var driftEnabled: Bool { animate && !ProbeConfig.noDrift && !reduceMotion }

    @ViewBuilder
    var body: some View {
        if ProbeConfig.flatBackdrop {
            DesignTokens.canvas.ignoresSafeArea()
        } else {
            backdrop
        }
    }

    private var backdrop: some View {
        ZStack {
            DesignTokens.canvas

            if useWallpaper, let wallpaper {
                // A resizable .scaledToFill() image reports its *aspect-ratio
                // ideal width* to the parent ZStack. With a 3456x1810 wallpaper
                // in a 1440 pt tall window that is 2749.5 pt: 189.5 pt WIDER
                // than the window. The root ZStack, VStack, top bar and pager
                // GeometryReader were all sized to that inflated width ->
                // grid metrics / pageExtent computed from 2697.5 instead of
                // 2508 (wrong icon proportions and paging), and the right-hand
                // top-bar buttons (search / hidden / settings) laid out
                // off-screen: "the settings are invisible".
                //
                // A flexible frame does NOT stop it (measured: still 2697.5).
                // Only making the image an OVERLAY of a size-less Color works:
                // auxiliary overlay content never participates in the parent's
                // layout size, so it is drawn at the window's real size and
                // clipped, while the 1.14 render scale still hides blur edges.
                Color.clear
                    .overlay {
                        Image(nsImage: wallpaper)
                            .resizable()
                            .scaledToFill()
                            .saturation(1.12)
                            .blur(radius: blur)
                            .scaleEffect(1.14)
                    }
                    .clipped()
                    .ignoresSafeArea()
            } else {
                ProceduralBackdrop(animate: driftEnabled)
                    .ignoresSafeArea()
            }

            // Aurora accents: static gradients whose *parent* is translated.
            // One transform instead of two animated child offsets means the
            // compositor can reuse the rasterised group on every vsync.
            // Colours are low-chroma steel blue plus ONE small warm signal glow:
            // .impeccable.md explicitly rules out violet / magenta / neon and
            // the additive plusLighter blend that used to push them to white.
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [DesignTokens.auroraCoolC.opacity(0.16), .clear],
                                         center: .center, startRadius: 10, endRadius: 520))
                    .frame(width: 1040, height: 1040)
                    .offset(x: -220, y: -260)

                Circle()
                    .fill(RadialGradient(colors: [DesignTokens.auroraWarm.opacity(DesignTokens.auroraWarmWeight), .clear],
                                         center: .center, startRadius: 10, endRadius: 480))
                    .frame(width: 960, height: 960)
                    .offset(x: 280, y: 240)
            }
            .offset(x: drift ? -20 : 20, y: drift ? -18 : 18)
            .animation(driftEnabled ? .easeInOut(duration: 22).repeatForever(autoreverses: true) : nil,
                       value: drift)

            // Dim + grade
            LinearGradient(colors: [
                .black.opacity(dim * 0.55),
                .black.opacity(dim),
                .black.opacity(dim * 0.85)
            ], startPoint: .top, endPoint: .bottom)

            RadialGradient(colors: [.clear, .black.opacity(0.42)],
                           center: .center, startRadius: 220, endRadius: 980)
        }
        .ignoresSafeArea()
        .onAppear { drift = driftEnabled }
        .onChange(of: driftEnabled) { _, on in drift = on }
    }
}

// MARK: - Built-in wallpaper

/// A slow "aurora" backdrop generated locally so the app never needs file
/// access. The artwork is rasterised once; only its parent layer drifts. The
/// old 15 fps TimelineView re-blurred four screen-sized gradients every frame
/// and stole GPU time from page and panel transitions.
struct ProceduralBackdrop: View {
    let animate: Bool
    @State private var drift = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let span = max(w, h)

            ZStack {
                LinearGradient(colors: [
                    DesignTokens.auroraSteel,
                    DesignTokens.canvas,
                    DesignTokens.auroraDeep
                ], startPoint: .topLeading, endPoint: .bottomTrailing)

                // Blobs keep FIXED positions. A single parent transform moves
                // all four at once, so the four screen-sized blur + screen
                // blend layers are composited once and then only translated.
                ZStack {
                    blob(colors: [DesignTokens.auroraCoolA, DesignTokens.auroraSteel],
                         diameter: span * 1.15,
                         x: w * 0.18, y: h * 0.26, opacity: 0.40)

                    blob(colors: [DesignTokens.auroraCoolB, DesignTokens.auroraSteel],
                         diameter: span * 0.95,
                         x: w * 0.82, y: h * 0.30, opacity: 0.34)

                    blob(colors: [DesignTokens.auroraCoolC, DesignTokens.auroraSteel],
                         diameter: span * 0.82,
                         x: w * 0.26, y: h * 0.86, opacity: 0.26)

                    blob(colors: [DesignTokens.auroraWarm, DesignTokens.auroraSteel],
                         diameter: span * 0.62,
                         x: w * 0.92, y: h * 0.95, opacity: DesignTokens.auroraWarmWeight)
                }
                .offset(x: drift ? -34 : 34, y: drift ? 22 : -22)
                .animation(animate ? .easeInOut(duration: 26).repeatForever(autoreverses: true) : nil,
                           value: drift)

                LinearGradient(colors: [.white.opacity(0.05), .clear, .black.opacity(0.18)],
                               startPoint: .top, endPoint: .bottom)
            }
            .frame(width: w, height: h)
            .clipped()
        }
        .onAppear { drift = animate }
        .onChange(of: animate) { _, on in drift = on }
    }

    /// Blur the artwork *before* positioning it, so the (now shared) animated
    /// transform moves cached layers rather than re-running the filter.
    private func blob(colors: [Color], diameter: CGFloat, x: CGFloat, y: CGFloat, opacity: Double) -> some View {
        let artwork = RadialGradient(
            colors: [colors[0].opacity(opacity), colors[0].opacity(opacity * 0.35), colors[1].opacity(0)],
            center: .center, startRadius: 0, endRadius: diameter / 2
        )
        .frame(width: diameter, height: diameter)
        .blur(radius: 60)

        return artwork
            .position(x: x, y: y)
            .blendMode(.screen)
    }
}
