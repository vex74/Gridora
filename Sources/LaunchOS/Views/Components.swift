import AppKit
import SwiftUI

// MARK: - Icon button

struct GlassIconButton: View {
    let systemName: String
    var help: String = ""
    var active: Bool = false
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(active || hover ? 1 : 0.70))
                .frame(width: 30, height: 30)
                .background {
                    Circle().fill(.white.opacity(active ? 0.20 : (hover ? 0.14 : 0.07)))
                }
                .overlay {
                    Circle().stroke(.white.opacity(0.12), lineWidth: 0.5)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help.isEmpty ? systemName : help)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Page dots

/// One page-dot strip for the whole app: the main grid and the open folder
/// panel both render this exact component, so the pager chrome cannot drift
/// apart. Geometry, hit target and animation live here only.
struct PagingDots: View {
    let count: Int
    let index: Int
    /// The main grid floats over the wallpaper and needs the capsule chrome;
    /// the folder panel already sits on its own glass surface, where a second
    /// capsule would just add noise. Dots stay pixel-identical either way.
    var chrome: Bool = true
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 9) {
            ForEach(0..<count, id: \.self) { page in
                Capsule(style: .continuous)
                    .fill(.white.opacity(page == index ? 0.95 : 0.30))
                    .frame(width: page == index ? 22 : 7, height: 7)
                    // The visible dot is 7 pt, but Launchpad's dots are
                    // clickable. Keep a comfortable target without changing
                    // the visual rhythm of the strip.
                    .frame(width: 20, height: 32)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(page) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("第 \(page + 1) 页，共 \(count) 页")
                    .accessibilityValue(page == index ? "当前页" : "")
                    .accessibilityHint("跳到这一页")
                    .accessibilityAddTraits(.isButton)
                    .animation(Motion.snap, value: index)
            }
        }
        .frame(height: 22)
        .padding(.horizontal, chrome ? 14 : 0)
        .padding(.vertical, chrome ? 5 : 0)
        .background {
            if chrome {
                Capsule(style: .continuous).fill(.white.opacity(0.06))
            }
        }
        .overlay {
            if chrome {
                Capsule(style: .continuous).stroke(.white.opacity(0.08), lineWidth: 0.5)
            }
        }
    }
}

struct PageDots: View {
    @EnvironmentObject var model: LauncherModel
    /// Publishes only at page crossings, so the dots never subscribe to the
    /// 120 Hz scroll offset.
    @ObservedObject var pageState: PageState

    var body: some View {
        PagingDots(count: model.pageCount, index: pageState.index) { page in
            model.goToPage(page)
        }
    }
}

// MARK: - App icon image

struct AppIconImage: View {
    let app: AppInfo
    var size: CGFloat
    var shadow: Bool = true

    var body: some View {
        Image(nsImage: app.icon)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(shadow ? 0.38 : 0), radius: size * 0.10, x: 0, y: size * 0.055)
    }
}

// MARK: - Folder icon

struct FolderIconView: View {
    @EnvironmentObject var model: LauncherModel
    @Environment(\.folderGlassPlateProvided) private var plateProvided
    let folder: Folder
    var size: CGFloat

    private var previewApps: [AppInfo] {
        folder.bundleIDs.prefix(9).compactMap { model.appsByID[$0] }
    }

    /// Same five settings as the open-folder panel. This is a value, not an
    /// extra subscription: the grid is rendered inside a rasterised page and
    /// must not gain per-frame observers.
    private var glass: FolderIconGlass {
        FolderIconGlass(settings: model.settings, size: size)
    }

    var body: some View {
        ZStack {
            if glass.enabled {
                // Inside a page, the real glass is drawn by the page's
                // background (outside drawingGroup); painting a backing here
                // would cover it. Outside a page (drag visual, hidden apps,
                // settings previews), the icon draws its own glass plate.
                if plateProvided {
                    EmptyView()
                } else {
                    FolderIconGlassSurface(glass: glass)
                }
            } else {
                legacyBacking(radius: size * 0.235)
            }

            // Larger previews: the old 0.24 squares inside 0.10 padding made
            // a folder read as noticeably smaller than a normal app icon.
            let inner = size * 0.26
            let spacing = size * 0.03
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(inner), spacing: spacing), count: 3),
                      spacing: spacing) {
                ForEach(Array(previewApps.enumerated()), id: \.element.id) { _, app in
                    Image(nsImage: app.icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: inner, height: inner)
                }
            }
            .padding(size * 0.075)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.35), radius: size * 0.10, x: 0, y: size * 0.05)
    }

    /// The original near-black tile, kept byte-for-byte for the disabled /
    /// rollback path so turning glass off never changes anything else.
    private func legacyBacking(radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return shape
            .fill(.white.opacity(0.13))
            .background(.ultraThinMaterial, in: shape)
            .overlay {
                shape.fill(LinearGradient(colors: [.white.opacity(0.06), .clear],
                                          startPoint: .top, endPoint: .bottom))
            }
            .overlay {
                shape.stroke(.white.opacity(0.18), lineWidth: 0.8)
            }
    }
}

// MARK: - Tile icon (app or folder)

struct TileIcon: View {
    @EnvironmentObject var model: LauncherModel
    let tile: Tile
    var size: CGFloat

    var body: some View {
        if let folder = tile.folder {
            FolderIconView(folder: folder, size: size)
        } else if let id = tile.bundleID, let app = model.appsByID[id] {
            AppIconImage(app: app, size: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(.white.opacity(0.12))
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Generic panel chrome

struct PanelBackground: View {
    var cornerRadius: CGFloat = DesignTokens.panelRadius
    var tint: Double = 0.97

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            DesignTokens.panelSurface.opacity(tint)
            LinearGradient(colors: [.white.opacity(0.07), .clear, .black.opacity(0.10)],
                           startPoint: .top, endPoint: .bottom)
        }
        .clipShape(shape)
        .overlay {
            shape.stroke(.white.opacity(0.16), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.55), radius: 48, x: 0, y: 22)
    }
}

// MARK: - Small toggle row

struct SettingsToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.vertical, 5)
    }
}

// MARK: - Slider row

struct SettingsSliderRow: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                Text(valueText)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
            }
            if step > 0 {
                Slider(value: $value, in: range, step: step)
                    .controlSize(.mini)
            } else {
                Slider(value: $value, in: range)
                    .controlSize(.mini)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Section label

struct SettingsSection: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(.white.opacity(0.36))
            .padding(.top, 14)
            .padding(.bottom, 3)
    }
}
