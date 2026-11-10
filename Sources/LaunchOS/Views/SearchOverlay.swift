import AppKit
import SwiftUI

/// Launchpad-style search: one compact field at the top of the screen and the
/// results sitting where the grid normally is. Since macOS 26 the chrome is
/// Liquid Glass (field, results panel and full-screen fog); every parameter
/// comes from `Settings` and is adjustable in Settings ▸ Appearance. Results
/// still occupy the grid's place rather than a separate window. The chrome
/// follows `.impeccable.md`: hairline border, monospaced counts, and the one
/// signal colour reserved for the focused field / selection.
struct SearchOverlay: View {
    @EnvironmentObject var model: LauncherModel
    /// Owned by `NativeSearchField`: focus is driven from AppKit, not from
    /// SwiftUI's @FocusState (see that file for the measured failure mode).
    @State private var editing = false

    /// Computed fresh on every body evaluation so a query change always
    /// produces a new result set. `SearchRenderProbe.note` is diagnostic only
    /// (a single bool read when disabled) and lets `--search-query-probe`
    /// prove the view recomputed rather than trusting the model alone.
    private var results: [AppInfo] {
        let value = model.searchResults
        SearchRenderProbe.note(query: model.query, count: value.count,
                               firstName: value.first?.name ?? "-")
        return value
    }
    private let accent = DesignTokens.signal

    var body: some View {
        GeometryReader { window in
            ZStack(alignment: .top) {
                // The click-catching scrim stays a plain colour so a tap on
                // empty space always closes search. Glass is layered above it
                // with hit testing disabled.
                Color.black.opacity(baseScrim)
                    .ignoresSafeArea()
                    .onTapGesture { model.closeSearch() }
                    .accessibilityHidden(true)

                if model.settings.searchGlassEnabled {
                    SearchGlassScrim(settings: model.settings)
                }

                VStack(spacing: 0) {
                    searchField
                        .padding(.top, model.menuBarHeight + 26)

                    resultsPanel(size: window.size)
                        .padding(.top, 18)

                    Spacer(minLength: 0)

                    footer(width: contentWidth(window.size.width))
                        .padding(.bottom, model.dockHeight + 20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Glass tints the backdrop by itself, so the opaque scrim is thinned
    /// while glass is on. Both paths read the same slider as the only source.
    private var baseScrim: Double {
        model.settings.searchGlassEnabled
            ? model.settings.searchScrim * 0.45
            : model.settings.searchScrim
    }

    private func availableHeight(_ total: CGFloat) -> CGFloat {
        let reserved = model.menuBarHeight + 26 + 42 + 22 + 18 + 34
            + model.dockHeight + 20 + 24 + 48 // glass panel padding
        return max(180, total - reserved)
    }

    private func resultsPanel(size: CGSize) -> some View {
        let width = contentWidth(size.width)
        return VStack(spacing: 0) {
            sectionLabel(width: width)
                .padding(.top, 20)
            if results.isEmpty {
                emptyState
            } else {
                resultsGrid(maxHeight: availableHeight(size.height), width: width)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
        .modifier(SearchGlassPanel(settings: model.settings))
    }

    private func contentWidth(_ total: CGFloat) -> CGFloat {
        min(900, max(360, total - 80))
    }

    // MARK: Field

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(editing ? 0.75 : 0.45))

            NativeSearchField(editing: $editing)
                .frame(maxWidth: .infinity)

            if !model.query.isEmpty {
                Button {
                    model.setSearchText("")
                    if let field = model.searchField {
                        _ = field.window?.makeFirstResponder(field)
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
            }

            Text("\(results.count)")
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.42))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(.white.opacity(0.07)))
        }
        .padding(.horizontal, 14)
        .frame(width: 460, height: 42)
        .modifier(SearchGlassPanel(settings: model.settings, fallback: .solidField))
        .overlay {
            RoundedRectangle(cornerRadius: CGFloat(model.settings.searchGlassRadius),
                             style: .continuous)
                .stroke(editing ? accent.opacity(0.85) : .white.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("搜索 App")
    }

    // MARK: Section label

    private func sectionLabel(width: CGFloat) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(accent.opacity(0.9))
                .frame(width: 2, height: 9)
            Text(model.query.isEmpty ? "常用 APP" : "搜索结果")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(.white.opacity(0.42))
        }
        .frame(width: width, alignment: .leading)
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.white.opacity(0.28))
            Text(model.query.isEmpty ? "开始输入以搜索" : "没有匹配的 App")
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.42))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 210)
    }

    // MARK: Results

    private func resultsGrid(maxHeight: CGFloat, width: CGFloat) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: LauncherModel.searchColumns)
        let shown = Array(results.enumerated())
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(shown, id: \.element.id) { index, app in
                        SearchResultItem(app: app,
                                         selected: index == model.searchSelection,
                                         iconSize: resultIconSize) {
                            model.closeSearch()
                            model.launch(app)
                        }
                        .id(index)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .frame(width: width, height: min(maxHeight, gridHeight))
            .onChange(of: model.searchSelection) { _, index in
                withAnimation(Motion.quick) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
    }

    /// Result tiles used a fixed 58 pt icon while the grid showed 150+ pt.
    /// Derive both from the grid's own icon size so the two surfaces keep the
    /// same visual proportion when the icon-size slider moves.
    private var resultIconSize: CGFloat {
        min(78, max(52, model.metrics.iconSize * 0.46))
    }

    private var resultRowHeight: CGFloat { resultIconSize + 48 }

    private var gridHeight: CGFloat {
        let rows = max(1, Int(ceil(Double(min(results.count, 24)) / Double(LauncherModel.searchColumns))))
        return CGFloat(rows) * resultRowHeight + 28
    }

    // MARK: Footer

    private func footer(width: CGFloat) -> some View {
        HStack(spacing: 16) {
            hint("↑ ↓ ← →", "选择")
            hint("Return", "打开")
            hint("esc", "返回网格")
            Spacer()
            hint("⌘← ⌘→", "翻页")
        }
        .frame(width: width)
        .padding(.vertical, 8)
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10, weight: .semibold).monospaced())
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.08)))
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.32))
        }
    }
}

struct SearchResultItem: View {
    let app: AppInfo
    let selected: Bool
    let iconSize: CGFloat
    let action: () -> Void

    @State private var hover = false
    private let accent = DesignTokens.signal
    private var radius: CGFloat { iconSize * 0.25 }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    if selected || hover {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(.white.opacity(0.10))
                            .frame(width: iconSize + 14, height: iconSize + 14)
                    }
                    AppIconImage(app: app, size: iconSize)
                }
                .frame(width: iconSize + 18, height: iconSize + 18)
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .stroke(accent, lineWidth: 2)
                    }
                }

                Text(app.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.82))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: iconSize + 38)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(app.name)
        .accessibilityHint("打开 App")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
