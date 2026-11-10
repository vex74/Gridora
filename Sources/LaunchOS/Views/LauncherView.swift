import AppKit
import SwiftUI

struct LauncherView: View {
    @EnvironmentObject var model: LauncherModel

    var body: some View {
        ZStack {
            // Value parameters, not an EnvironmentObject: dragging an icon or
            // scrolling a page must never re-evaluate the expensive backdrop.
            // Quantising the two slider-fed values stops the full-screen blur
            // from being rebuilt on every slider frame. 5 pt / 2% steps are
            // imperceptible, and the backdrop view value stays unchanged for
            // most of those frames so SwiftUI can skip its body entirely.
            BackgroundView(useWallpaper: model.settings.useWallpaper,
                           wallpaper: model.wallpaper,
                           blur: model.quantizedBackdropBlur,
                           dim: model.quantizedBackdropDim,
                           animate: model.isShown)

            VStack(spacing: 0) {
                TopBar()
                PagerView(scroll: model.scroll)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                BottomBar()
            }
            .padding(.horizontal, 26)
            .padding(.top, 14 + model.menuBarHeight)
            .padding(.bottom, 12 + model.dockHeight)
            // macOS 15 keeps the grid perfectly still. A SwiftUI
            // `scaleEffect(1.025)` / `offset(y: 10)` used to live here; on a
            // pure cross-fade those made every icon visibly jump at the first
            // frame of the fade-out, and they also fought the old centre-out
            // layer transform. Show/hide is now entirely window alpha, so
            // `isShown` only drives the backdrop's ambient drift. No per-tile
            // animation state: rasterised pages untouched.

            PanelLayer()
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        // Split interaction state is injected once. Each view observes only
        // the frequency band it actually needs.
        .environmentObject(model.pageState)
        .environmentObject(model.dragInfo)
        .environmentObject(model.dragMotion)
        .environmentObject(model.folderDragInfo)
        .environmentObject(model.folderDragMotion)
    }
}

// MARK: - Overlays

/// Overlays live in their own subtree. Scoping the implicit animations here
/// keeps the background, grid and bars out of the panel transition transaction.
struct PanelLayer: View {
    @EnvironmentObject var model: LauncherModel

    var body: some View {
        ZStack {
            if model.isLoading {
                LoadingOverlay()
                    .transition(.opacity)
            }

            if let folderID = model.openFolderID, let folder = model.folder(folderID) {
                FolderOverlay(folderID: folderID, folder: folder)
                    // The scale-in is owned by FolderOverlay itself so it can
                    // anchor to the clicked tile; the parent only cross-fades.
                    // No PreferenceKey on the paging path.
                    .transition(.opacity)
                    .zIndex(5)
            }

            if model.searchOpen {
                // A fresh identity per open resets @FocusState. Without this,
                // SwiftUI can reuse the previous search subtree: `focused`
                // stays true, the async focus request in onAppear does nothing,
                // and typing no longer reaches the field after the first
                // search. Search is a separate subtree, so this never touches
                // the paging path.
                SearchOverlay()
                    .id(model.searchGeneration)
                    .transition(.opacity)
                    .zIndex(6)
            }

            if model.hiddenOpen {
                HiddenAppsOverlay()
                    .transition(.opacity)
                    .zIndex(7)
            }

            if model.settingsOpen {
                SettingsOverlay()
                    .transition(.opacity)
                    .zIndex(8)
            }
        }
        .animation(Motion.panel, value: model.searchOpen)
        .animation(Motion.panel, value: model.settingsOpen)
        .animation(Motion.panel, value: model.hiddenOpen)
        .animation(Motion.panel, value: model.openFolderID)
    }
}

// MARK: - Top bar

struct TopBar: View {
    @EnvironmentObject var model: LauncherModel
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center) {
            TimelineView(.periodic(from: .now, by: 20)) { context in
                HStack(spacing: 10) {
                    Text(context.date.formatted(.dateTime.month().day().weekday(.abbreviated)))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                    Text(context.date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                }
            }

            Spacer()

            HStack(spacing: 8) {
                GlassIconButton(systemName: "magnifyingglass", help: "搜索 App  ⌘F",
                                active: model.searchOpen) {
                    if model.searchOpen { model.closeSearch() } else { model.openSearch() }
                }
                GlassIconButton(systemName: "eye.slash", help: "已隐藏的 App  ⌘⇧H", active: model.hiddenOpen) {
                    model.showHidden()
                }
                GlassIconButton(systemName: "slider.horizontal.3", help: "设置  ⌘,", active: model.settingsOpen) {
                    model.showSettings()
                }
            }
            // Keep the three entries permanently discoverable. They used to be
            // opacity 0 unless the pointer sat in the top strip, so any layout
            // drift (or simply not knowing about the hover) read as "settings
            // are gone". Low-key by default, full strength on hover; Motion.quick
            // collapses to 0.001s under Reduce Motion.
            .opacity(hovering ? 1 : 0.45)
            .animation(Motion.quick, value: hovering)
        }
        .frame(height: 38)
        .contentShape(Rectangle())
        .onHover { value in
            withAnimation(Motion.quick) { hovering = value }
        }
        .onAppear { hovering = false }
    }
}

// MARK: - Bottom bar

struct BottomBar: View {
    @EnvironmentObject var model: LauncherModel
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 2) {
            PageDots(pageState: model.pageState)

            Text(hint)
                .font(.system(size: 10.5, weight: .regular))
                .foregroundStyle(.white.opacity(hovering ? 0.5 : 0.26))
                .animation(Motion.quick, value: hovering)
                .frame(height: 14)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var hint: String {
        if model.settings.vertical {
            return "上下滚动翻页 · 输入字母搜索 · Return 打开 · ⌘, 设置"
        }
        return "左右滚动翻页 · 输入字母搜索 · Return 打开 · ⌘, 设置"
    }
}

// MARK: - Loading

struct LoadingOverlay: View {
    @State private var spin = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.white.opacity(0.8))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(reduceMotion ? nil : .linear(duration: 1.6).repeatForever(autoreverses: false),
                               value: spin)
                Text("正在扫描应用…")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .onAppear { spin = !reduceMotion }
    }
}

// MARK: - Empty state

struct EmptyGridMessage: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.3x3")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
            Text("这一页还没有 App")
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.45))
        }
    }
}

// MARK: - Menu bar cover

/// Painted by a click-through window above the launcher: hides the real menu
/// bar (like Launchpad does) while the Dock below the launcher stays live.
///
/// The main window sits at level 19, *below* the system menu bar, so its
/// backdrop cannot cover that strip. This second window fills the gap. It
/// draws the very same `BackgroundView` as the main window, laid out at full
/// screen size and then clipped to the menu-bar height — so a blurred
/// wallpaper continues right to the top edge instead of ending in a solid
/// dark band. Keeping the full-screen layout is what aligns the two copies
/// pixel for pixel; clipping a short strip would rescale the wallpaper.
struct MenuBarCover: View {
    @EnvironmentObject var model: LauncherModel
    /// The cover is a separate NSWindow, so folder drag state has to be
    /// injected separately: `outsidePanel` thins the fog in BOTH windows.
    @EnvironmentObject var folderDragInfo: FolderDragInfo

    /// One value, shared with FolderOverlay / SearchOverlay. Without it the
    /// top strip keeps the clean wallpaper blur while the rest of the screen
    /// gets glass + scrim — the seam macOS 15 does not have.
    private var fog: BackdropFog {
        let state = BackdropFog.state(openFolderID: model.openFolderID,
                                      searchOpen: model.searchOpen,
                                      outsidePanel: folderDragInfo.outsidePanel)
        return BackdropFog.make(settings: model.settings, state: state)
    }

    var body: some View {
        ZStack {
            BackgroundView(useWallpaper: model.settings.useWallpaper,
                           wallpaper: model.wallpaper,
                           blur: model.quantizedBackdropBlur,
                           dim: model.quantizedBackdropDim,
                           animate: false)

            // Clipped by the same mask as the backdrop: the fog must never
            // spill below the menu-bar strip and cover the main window.
            if fog.visibleOnCover {
                BackdropFogSurface(fog: fog)
            }
        }
        .mask(alignment: .top) {
            VStack(spacing: 0) {
                Color.black.frame(height: model.menuBarHeight)
                Color.clear
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
    }
}
