import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// Sidebar categories of the light settings panel; published on the model so
/// demo flags can open a specific page and the selection survives reopening.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "通用"
    case appearance = "外观"
    case layout = "布局"
    case locations = "应用位置"
    case hidden = "已隐藏 App"
    case sync = "同步"
    case about = "关于"

    var id: String { rawValue }
}

private typealias Page = SettingsPage

struct SettingsOverlay: View {
    @EnvironmentObject var model: LauncherModel

    @State private var selectedExtra: Int?
    /// Pointer and keyboard feedback for the sidebar. Plain button styles left
    /// every row visually inert (no hover, no focus ring).
    @State private var hoveredPage: Page?
    @FocusState private var focusedPage: Page?
    @FocusState private var doneFocused: Bool
    /// Feedback for the one-shot layout tools (compact / reset / backup / restore).
    @State private var layoutStatus = ""
    @State private var layoutStatusIsError = false
    @State private var showResetConfirm = false
    /// Mirrors the system-wide Dock preference; not part of our own state file.
    @State private var hideDockIndicator = DockIndicator.isHidden
    /// Recording state and feedback for the four shortcut rows.
    @State private var recordingRole: HotKeyRole?
    @State private var hotKeyFeedback = ""
    /// Sync state lives outside PersistedState: the setting is per-Mac, and a
    /// snapshot must never overwrite the switch that enabled it.
    @ObservedObject private var sync = LayoutSync.shared

    private var page: Page { model.settingsPage }

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { model.settingsOpen = false }

            HStack(spacing: 0) {
                sidebar
                content
            }
            .frame(width: 744, height: 508)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.frameRadius, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 26, y: 10)
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.frameRadius, style: .continuous)
                .stroke(.black.opacity(0.12), lineWidth: 0.5))
            .environment(\.colorScheme, .light)
        }
        .onChange(of: model.settings.columns) { _, _ in model.scheduleLayoutCommit() }
        .onChange(of: model.settings.rows) { _, _ in model.scheduleLayoutCommit() }
        .onChange(of: model.settings.vertical) { _, _ in model.scheduleLayoutCommit() }
        .onChange(of: model.settings.iconScale) { _, _ in model.scheduleLayoutCommit() }
        .onChange(of: model.settings.gridInsets) { _, _ in model.scheduleLayoutCommit() }
        .onChange(of: model.settings.showLabels) { _, _ in model.scheduleLayoutCommit() }
        .onChange(of: model.settings.autoHideUnused) { _, isOn in
            if isOn { model.applyAutoHide() } else { model.restoreAutoHidden() }
            model.persist()
        }
        .onChange(of: model.settings.autoHideDays) { _, _ in
            if model.settings.autoHideUnused { model.applyAutoHide() }
        }
        .onChange(of: model.settings.useWallpaper) { _, _ in
            // Refresh on both edges: turning it off releases the cached image,
            // turning it on retries detection. Never let a failed lookup flip
            // this switch back off.
            model.refreshWallpaper(force: true)
            model.persist()
        }
        .onChange(of: model.settings.launchAtLogin) { _, on in
            if #available(macOS 14.0, *) {
                do {
                    if on { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                } catch {
                    model.settings.launchAtLogin = !on
                }
            }
            model.persist()
        }
        .onChange(of: model.settings.extraFolders) { _, folders in
            AppScanner.extraFolders = folders
            model.scanApps()
            model.persist()
        }
        .onChange(of: model.settings.quitOnHide) { _, _ in model.persist() }
        .onChange(of: model.settings.showInDock) { _, on in
            // Info.plist starts us as .accessory; switching to .regular at
            // runtime claims a Dock tile again (reversible without rebuild).
            NSApp.setActivationPolicy(on ? .regular : .accessory)
            model.persist()
        }
        .onChange(of: model.settings.glassEnabled) { _, _ in model.persist() }
        .onChange(of: model.settings.glassStyle) { _, _ in model.persist() }
        .onChange(of: model.settings.glassTint) { _, _ in model.persist() }
        .onChange(of: model.settings.glassRadius) { _, _ in model.persist() }
        .onChange(of: model.settings.glassScrim) { _, _ in model.persist() }
        .onChange(of: model.settings.launcherHotKey) { _, _ in
            // The Carbon registration is owned by AppDelegate; changing the
            // stored value is enough, no restart or "apply" button needed.
            model.persist()
            model.onHotKeysChanged?()
        }
        .onChange(of: model.settings.previousPageHotKey) { _, _ in model.persist() }
        .onChange(of: model.settings.nextPageHotKey) { _, _ in model.persist() }
        .onChange(of: model.settings.searchHotKey) { _, _ in model.persist() }
        .onChange(of: model.settings.letterOpensSearch) { _, _ in model.persist() }
        .onChange(of: hideDockIndicator) { _, hidden in
            DockIndicator.setHidden(hidden)
        }
        .onAppear { hideDockIndicator = DockIndicator.isHidden }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Page.allCases) { item in
                Button {
                    withAnimation(Motion.quick) { model.settingsPage = item }
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: DesignTokens.rowTitle, weight: .medium))
                        .foregroundStyle(page == item ? .white : DesignTokens.settingsText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            RoundedRectangle(cornerRadius: DesignTokens.controlRadius, style: .continuous)
                                .fill(page == item ? DesignTokens.settingsAccent
                                      : (hoveredPage == item ? DesignTokens.hoverFill : .clear))
                        }
                }
                .buttonStyle(SettingsButtonStyle(hoverFill: Color.clear))
                .onHover { hoveredPage = $0 ? item : nil }
                .focused($focusedPage, equals: item)
                .overlay {
                    if focusedPage == item { focusRing }
                }
                .accessibilityLabel(item.rawValue)
                .accessibilityAddTraits(page == item ? [.isButton, .isSelected] : .isButton)
            }
            Spacer()
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.top, 18)
        .frame(width: 152)
        .background(LinearGradient(colors: [
            Color(red: 0.975, green: 0.973, blue: 0.98),
            Color(red: 0.94, green: 0.938, blue: 0.955)
        ], startPoint: .top, endPoint: .bottom))
    }

    /// 2pt ring drawn 2pt outside the control's bounds; shared by the sidebar
    /// and the Done button so keyboard focus is visible on the light panel.
    private var focusRing: some View {
        RoundedRectangle(cornerRadius: DesignTokens.controlRadius, style: .continuous)
            .inset(by: DesignTokens.focusRingInset)
            .stroke(DesignTokens.settingsAccent, lineWidth: DesignTokens.focusRingWidth)
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    switch page {
                    case .general: generalPage
                    case .appearance: appearancePage
                    case .layout: layoutPage
                    case .locations: locationsPage
                    case .hidden: hiddenPage
                    case .sync: syncPage
                    case .about: aboutPage
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            Divider().overlay(DesignTokens.settingsHairline)
            HStack {
                Spacer()
                Button {
                    model.settingsOpen = false
                } label: {
                    Text("完成")
                        .font(.system(size: DesignTokens.rowTitle, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: DesignTokens.controlRadius, style: .continuous)
                            .fill(DesignTokens.settingsAccent))
                }
                .buttonStyle(SettingsButtonStyle(hoverFill: Color.clear))
                .focused($doneFocused)
                .overlay {
                    if doneFocused { focusRing }
                }
                .accessibilityLabel("完成设置")
                .accessibilityHint("关闭设置面板并返回启动台")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .frame(width: 592)
        .background(Color.white)
    }

    // MARK: 通用

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            card {
                toggleRow(title: "开机时自动启动", isOn: $model.settings.launchAtLogin)
                divider
                toggleRow(title: "关闭启动台时彻底退出进程",
                          subtitle: "默认关闭：关闭后进程以无程序坞图标、无运行点、不接管菜单栏的方式常驻，随时按启动键或点程序坞图标唤起。打开则每次关闭都结束进程，系统级启动键随之失效，只能用程序坞图标重新打开",
                          isOn: $model.settings.quitOnHide)
                divider
                toggleRow(title: "在程序坞显示运行图标",
                          subtitle: "默认关闭：启动台是瞬时面板，点程序坞图标不弹跳、不显示运行点、不接管菜单栏。打开则回到普通应用形态",
                          isOn: $model.settings.showInDock)
            }

            header(title: "快捷键",
                   caption: "点「更改…」后直接按一个按键即可，不需要组合键；Esc 取消，右侧 ⓧ 恢复该项默认。「显示启动台」支持任意单独按键（F3、字母、数字、空格等）或组合键；其余三项仍需 ⌘ / ⌃ / ⌥ / ⇧ 或 F1–F15 功能键，四项不能重复。默认的 ⌃⌥Space 附带内置 ⌃⌥L / F4 备用组合，改成自定义键后自动释放。单键会全局占用该按键：进程常驻时，在其他 App 里按它同样会唤起启动台，连启动台自己的搜索框也无法再输入这个字符。")

            card {
                hotKeyRow(.launcher)
                divider
                hotKeyRow(.previousPage)
                divider
                hotKeyRow(.nextPage)
                divider
                hotKeyRow(.search)

                if !hotKeyFeedback.isEmpty {
                    Text(hotKeyFeedback)
                        .font(.system(size: DesignTokens.caption))
                        .foregroundStyle(DesignTokens.settingsMuted)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        .fixedSize(horizontal: false, vertical: true)
                }
                divider
                toggleRow(title: "输入字母直接打开搜索",
                          subtitle: "关闭后只通过快捷键或顶部搜索按钮进入搜索，避免中文输入法首字被注入到尚未创建的输入框",
                          isOn: $model.settings.letterOpensSearch)
                divider
                Text("默认保持进程常驻（无程序坞图标、无运行点、不接管菜单栏）：关闭启动台后仍可随时按「显示启动台」的按键唤起，点程序坞图标也可再次打开或关闭。若在本页顶部开启「关闭启动台时彻底退出进程」，进程结束后启动键会失效。")
                    .font(.system(size: DesignTokens.caption))
                    .foregroundStyle(DesignTokens.settingsMuted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .fixedSize(horizontal: false, vertical: true)
                divider
                actionRow(title: "恢复全部默认快捷键", systemImage: "arrow.counterclockwise") {
                    resetAllHotKeys()
                }
            }

            header(title: "滚动",
                   caption: "一次滚动动作最多翻一页：高分辨率滚轮一次拨动发出的连续事件会合并，不会连翻。「鼠标滚轮行数」决定每拨几次翻一页；「滚动速度」同时调节触控板滑动幅度、轻扫门槛、连续拨动的合并窗口与所有翻页动画的快慢。两项都可随时拖动调节，无需重启。")

            card {
                sliderRow(title: "鼠标滚轮行数",
                          valueText: model.settings.wheelLines <= 1 ? "每拨一次翻一页"
                              : "每 \(model.settings.wheelLines) 次拨动翻一页",
                          value: intBinding(\.wheelLines, range: 1...8),
                          range: 1...8, step: 1)
                divider
                sliderRow(title: "滚动速度",
                          valueText: String(format: "%.2f×", model.settings.scrollSpeed),
                          value: $model.settings.scrollSpeed,
                          range: 0.4...2.0,
                          under: ["慢", "默认", "快"])
                divider
                actionRow(title: "恢复默认滚动设置", systemImage: "arrow.counterclockwise") {
                    model.settings.wheelLines = 1
                    model.settings.scrollSpeed = 1.0
                    model.persist()
                }
                divider
                toggleRow(title: "反转滚动方向",
                          subtitle: "如果翻页方向和手势相反，打开这里",
                          isOn: $model.settings.reverseScroll)
                divider
                toggleRow(title: "隐藏 Dock 运行指示点",
                          subtitle: "全局生效：所有 App 图标下方的小圆点都会隐藏，切换后 Dock 会重启一下",
                          isOn: $hideDockIndicator)
            }
        }
    }

    // MARK: - Shortcut rows

    private func hotKeyRow(_ role: HotKeyRole) -> some View {
        let recording = recordingRole == role
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(role.title)
                    .font(.system(size: DesignTokens.rowTitle))
                    .foregroundStyle(DesignTokens.settingsText)
                Text(recording ? "请按下按键…" : role.chord(in: model.settings).label)
                    .font(.system(size: DesignTokens.caption).monospacedDigit())
                    .foregroundStyle(recording
                                     ? DesignTokens.settingsDanger
                                     : DesignTokens.settingsMuted)
            }
            Spacer(minLength: 8)
            Button(recording ? "取消" : "更改…") { toggleRecording(role) }
                .buttonStyle(SettingsButtonStyle())
                .accessibilityLabel(recording ? "取消录制\(role.title)快捷键" : "更改\(role.title)快捷键")
            Button { resetHotKey(role) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(DesignTokens.settingsMuted)
            }
            .buttonStyle(SettingsButtonStyle(hoverFill: Color.clear))
            .accessibilityLabel("恢复\(role.title)的默认快捷键")
            .help("恢复默认 \(role.defaultChord.label)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 46)
    }

    private func toggleRecording(_ role: HotKeyRole) {
        if recordingRole == role {
            HotKeyRecorder.cancel()
            recordingRole = nil
            hotKeyFeedback = "已取消，快捷键保持不变"
            return
        }
        recordingRole = role
        hotKeyFeedback = ""
        HotKeyRecorder.begin(validate: { combo in
            HotKeyRules.rejection(for: combo, role: role, settings: model.settings)
        }) { combo, message in
            recordingRole = nil
            if let combo {
                // copy-modify-write: one @Published write, so onChange fires
                // exactly once and the Carbon re-registration follows.
                var settings = model.settings
                role.set(combo, in: &settings)
                model.settings = settings
                if role == .launcher {
                    var notes: [String] = []
                    if combo.modifiers == 0 && !combo.isBareFunctionKey {
                        notes.append("单键会全局占用该按键，其他 App 与启动台搜索框里按它都会唤起启动台")
                    }
                    if model.settings.quitOnHide {
                        notes.append("当前「关闭启动台时彻底退出进程」已开启：关闭后系统会注销启动键，需要随时按键唤起请关闭该开关")
                    }
                    if !notes.isEmpty {
                        hotKeyFeedback = message + "。" + notes.joined(separator: "；")
                        return
                    }
                }
            }
            hotKeyFeedback = message
        }
    }

    private func resetHotKey(_ role: HotKeyRole) {
        let chord = role.defaultChord
        if let reason = HotKeyRules.rejection(for: chord, role: role, settings: model.settings) {
            hotKeyFeedback = "无法恢复默认：\(reason)"
            return
        }
        HotKeyRecorder.cancel()
        recordingRole = nil
        var settings = model.settings
        role.set(chord, in: &settings)
        model.settings = settings
        hotKeyFeedback = "\(role.title) 已恢复 \(chord.label)"
    }

    private func resetAllHotKeys() {
        HotKeyRecorder.cancel()
        recordingRole = nil
        var settings = model.settings
        for role in HotKeyRole.allCases {
            role.set(role.defaultChord, in: &settings)
        }
        model.settings = settings
        hotKeyFeedback = "已恢复全部默认：⌃⌥Space / ⌘← / ⌘→ / ⌘F"
    }

    // MARK: 同步

    private var syncPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            header(title: "布局同步",
                   caption: "只同步 App 摆放顺序、文件夹与隐藏列表；分页会按本机网格行列重排，外观、滚动速度等设置保留在本机。")

            card {
                toggleRow(title: "同步图标摆放位置",
                          subtitle: "在 iCloud Drive（或你指定的云盘目录）保存一份布局快照，其他 Mac 读取同一个文件即可同步。",
                          isOn: Binding(get: { sync.isEnabled },
                                        set: { sync.setEnabled($0) }))
                divider
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("同步位置")
                            .font(.system(size: 13))
                            .foregroundStyle(.black.opacity(0.85))
                        Text(sync.folderDescription)
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(.black.opacity(0.45))
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Text(sync.iCloudBadge)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.black.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(sync.status)
                            .font(.system(size: 11))
                            .foregroundStyle(.black.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(minHeight: 58)
            }

            card {
                actionRow(title: "更改同步文件夹…", systemImage: "folder") {
                    sync.chooseFolder()
                }
                divider
                actionRow(title: "在访达中显示同步文件夹", systemImage: "magnifyingglass") {
                    sync.revealInFinder()
                }
                divider
                actionRow(title: "恢复默认位置（iCloud Drive）", systemImage: "arrow.uturn.backward") {
                    sync.useDefaultFolder()
                }
                divider
                actionRow(title: "立即上传本机布局", systemImage: "arrow.up") {
                    sync.pushNow(force: true)
                }
                divider
                actionRow(title: "从同步文件恢复", systemImage: "arrow.down") {
                    sync.pullNow()
                }
            }

            Text("首次开启时若已有同步文件会采用它；想以本机为准，点「立即上传本机布局」。冲突以最后一次修改为准（比较快照时间戳）。App 启动与每次激活时检查一次，运行期间每 12 秒再检查一次。开启「优化 Mac 储存空间」时，另一台 Mac 可能先显示「正在从 iCloud 下载」，下载完成后自动采用云端布局，期间不会用本机旧布局覆盖。")
                .font(.system(size: 11))
                .foregroundStyle(.black.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 外观

    private var appearancePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            header(title: "壁纸 · 背景",
                   caption: "模糊 0–90 / 暗度 0–80%。自定义壁纸优先于程序化背景；解析失败时只显示状态并回退，不会改写开关。")

            card {
                toggleRow(title: "使用桌面壁纸",
                          subtitle: "模糊当前桌面壁纸作为背景（支持图片文件夹）",
                          isOn: $model.settings.useWallpaper)
                divider
                wallpaperStatusRow
                divider
                actionRow(title: "选择图片或文件夹…", systemImage: "photo") { chooseWallpaper() }
                if model.settings.wallpaperPath != nil {
                    divider
                    actionRow(title: "恢复自动检测系统壁纸",
                              systemImage: "arrow.counterclockwise") {
                        model.clearWallpaperPath()
                    }
                }
            }

            card {
                sliderRow(title: "模糊",
                          valueText: model.settings.backgroundBlur == 0 ? "关闭" : "\(Int(model.settings.backgroundBlur))",
                          value: $model.settings.backgroundBlur,
                          range: 0...90,
                          under: ["关闭", "轻度", "", "默认"])
                divider
                sliderRow(title: "暗度",
                          valueText: "\(Int(model.settings.backgroundDim * 100))%",
                          value: $model.settings.backgroundDim,
                          range: 0...0.8,
                          under: ["轻", "默认", "深"])
                divider
                toggleRow(title: "显示 App 名称",
                          subtitle: "关闭后只显示图标，更干净",
                          isOn: $model.settings.showLabels)
            }

            header(title: "液态玻璃",
                   caption: "搜索框、搜索结果、文件夹面板、网格里缩小的文件夹图标，以及选中 / 悬停 App 时的高亮，全部共用这一组参数、同步变化。macOS 26 及以上使用系统玻璃材质，旧系统退回半透明材质。着色 0–75% / 圆角 6–36pt / 压暗 0–60%；圆角是面板的半径，搜索框按 58% 等比推导，高亮按图标尺寸等比缩放。")

            card {
                // All stages read the same group, so they always move together.
                GlassPreviewStage()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                divider
                FolderGlassPreviewStage()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                divider
                SelectionHighlightPreviewStage()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                divider
                toggleRow(title: "使用液态玻璃",
                          subtitle: "关闭后搜索、文件夹面板、文件夹图标与选中高亮一起回到原来的实底样式",
                          isOn: $model.settings.glassEnabled)
                divider
                segmentedRow(title: "玻璃风格",
                             selection: $model.settings.glassStyle)
                divider
                sliderRow(title: "着色浓度",
                          valueText: "\(Int(model.settings.glassTint * 100))%",
                          value: $model.settings.glassTint,
                          range: Settings.glassTintRange,
                          under: ["通透", "", "浓"])
                divider
                sliderRow(title: "圆角",
                          valueText: "\(Int(model.settings.glassRadius)) pt",
                          value: $model.settings.glassRadius,
                          range: Settings.glassRadiusRange,
                          step: 1,
                          under: ["方正", "", "圆润"])
                divider
                sliderRow(title: "压暗",
                          valueText: "\(Int(model.settings.glassScrim * 100))%",
                          value: $model.settings.glassScrim,
                          range: Settings.glassScrimRange,
                          under: ["轻", "默认", "深"])
                divider
                actionRow(title: "恢复默认玻璃设置",
                          systemImage: "arrow.counterclockwise") {
                    model.settings.glassEnabled = true
                    model.settings.glassStyle = .regular
                    model.settings.glassTint = Settings.defaultGlassTint
                    model.settings.glassRadius = Settings.defaultGlassRadius
                    model.settings.glassScrim = Settings.defaultGlassScrim
                    model.persist()
                }
            }
        }
    }

    private var wallpaperStatusRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("壁纸状态")
                .font(.system(size: 13))
                .foregroundStyle(.black.opacity(0.85))
                .fixedSize()
            Spacer(minLength: 8)
            Text(model.wallpaperStatus)
                .font(.system(size: 11))
                .foregroundStyle(model.wallpaper == nil
                                 ? DesignTokens.settingsWarning
                                 : Color.black.opacity(0.45))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 36)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("壁纸状态：\(model.wallpaperStatus)")
    }

    private func chooseWallpaper() {
        // The picker must sit above the level-19 launcher and level-26 menu
        // cover, and the app must stay active/resident while it is open.
        let panel = FilePanels.makeWallpaperPanel()
        FilePanels.prepare(panel)
        panel.begin { response in
            FilePanels.release()
            guard response == .OK, let url = panel.url else { return }
            model.applyWallpaperPath(url)
        }
    }

    // MARK: 布局

    private var layoutPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            header(title: "布局",
                   caption: "默认 5×7。图标 pt 读数按当前格子的可用高度实时换算，滑块百分比不变。")

            card {
                sliderRow(title: "行数",
                          valueText: "\(model.settings.rows)",
                          value: intBinding(\.rows, range: 3...7),
                          range: 3...7, step: 1,
                          controlWidth: 220)
                divider
                sliderRow(title: "列数",
                          valueText: "\(model.settings.columns)",
                          value: intBinding(\.columns, range: 4...9),
                          range: 4...9, step: 1,
                          controlWidth: 220)
                divider
                sliderRow(title: "图标大小",
                          valueText: "\(Int(model.settings.iconScale * 100))% · \(Int(model.metrics.iconSize))pt",
                          value: $model.settings.iconScale,
                          range: Settings.iconScaleRange,
                          under: ["78%", "", "\(Int(Settings.iconScaleRange.upperBound * 100))%"])
                divider
                VStack(alignment: .leading, spacing: 2) {
                    Text("App 区域边距 · 四边独立，0–18% 按较短边换算")
                        .font(.system(size: DesignTokens.caption, weight: .medium))
                        .foregroundStyle(DesignTokens.settingsMuted)
                    Text("边距会压缩每格高度：调上／下时右侧 pt 读数随之变化，图标大小百分比不变。")
                        .font(.system(size: DesignTokens.micro))
                        .foregroundStyle(DesignTokens.settingsFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                sliderRow(title: "上",
                          valueText: insetPointsText(.top),
                          value: insetBinding(.top),
                          range: Settings.gridInsetRange)
                divider
                sliderRow(title: "下",
                          valueText: insetPointsText(.bottom),
                          value: insetBinding(.bottom),
                          range: Settings.gridInsetRange)
                divider
                sliderRow(title: "左",
                          valueText: insetPointsText(.left),
                          value: insetBinding(.left),
                          range: Settings.gridInsetRange)
                divider
                sliderRow(title: "右",
                          valueText: insetPointsText(.right),
                          value: insetBinding(.right),
                          range: Settings.gridInsetRange)
                divider
                toggleRow(title: "纵向翻页",
                          subtitle: "打开后改为沿屏幕上下分页",
                          isOn: Binding(get: { model.settings.vertical },
                                        set: { model.settings.vertical = $0 }))
            }

            card {
                actionRowWithButton(title: "紧凑页面",
                                    subtitle: "重新排列 App 以填满页面并删除空白页面，从而减少页数。",
                                    buttonTitle: "整理") { compactLayout() }
                divider
                actionRowWithButton(title: "重置布局",
                                    subtitle: "将应用顺序和分组恢复默认，已隐藏的 App 不受影响。",
                                    buttonTitle: "重置…",
                                    destructive: true) { showResetConfirm = true }
            }

            card {
                actionRowWithButton(title: "备份布局",
                                    subtitle: "将当前排列、分组与隐藏状态保存到文件。",
                                    buttonTitle: "备份…") { backupLayout() }
                divider
                actionRowWithButton(title: "恢复布局",
                                    subtitle: "从文件中恢复已保存的排列，不改动本机行列与外观设置。",
                                    buttonTitle: "恢复…") { restoreLayout() }
            }

            if !layoutStatus.isEmpty {
                Text(layoutStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(layoutStatusIsError
                        ? DesignTokens.settingsDanger
                        : .black.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
            }

            card {
                actionRow(title: "重置全部设置", systemImage: "arrow.triangle.2.circlepath", destructive: true) {
                    model.resetAll()
                }
            }
        }
        .alert("重置布局？", isPresented: $showResetConfirm) {
            Button("取消", role: .cancel) { }
            Button("重置布局", role: .destructive) {
                model.resetLayout()
                setLayoutStatus("已重置为默认顺序与分组")
            }
        } message: {
            Text("应用顺序与分组会恢复默认，已隐藏的 App 不受影响。")
        }
    }

    // MARK: 布局工具

    private func setLayoutStatus(_ text: String, isError: Bool = false) {
        layoutStatus = text
        layoutStatusIsError = isError
    }

    private func compactLayout() {
        let result = model.compactPages()
        if result.before == result.after {
            setLayoutStatus("已整理 · 当前 \(result.after) 页，没有空白页")
        } else {
            setLayoutStatus("已整理 · \(result.before) 页 → \(result.after) 页")
        }
    }

    private func backupLayout() {
        let panel = NSSavePanel()
        panel.title = "备份布局"
        panel.message = "只保存排列、分组与隐藏状态；行列数、图标大小等本机设置不会写入文件。"
        panel.nameFieldStringValue = LayoutBackup.defaultFileName()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        FilePanels.prepare(panel)
        panel.begin { response in
            FilePanels.release()
            guard response == .OK, let url = panel.url else { return }
            do {
                let snapshot = LayoutBackup.snapshot(pages: model.pages,
                                                     hidden: model.hiddenTiles,
                                                     manualHidden: model.manualHidden,
                                                     pinned: model.pinned)
                try LayoutBackup.write(snapshot, to: url)
                setLayoutStatus("已备份到 \(url.lastPathComponent)")
            } catch {
                setLayoutStatus(error.localizedDescription, isError: true)
            }
        }
    }

    private func restoreLayout() {
        let panel = NSOpenPanel()
        panel.title = "恢复布局"
        panel.message = AppBrand.restorePanelMessage
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        FilePanels.prepare(panel)
        panel.begin { response in
            FilePanels.release()
            guard response == .OK, let url = panel.url else { return }
            do {
                // Strict decode happens before anything is mutated.
                let layout = try LayoutBackup.read(from: url)
                model.applySyncedLayout(layout)
                setLayoutStatus("已从 \(url.lastPathComponent) 恢复 \(layout.pages.count) 页")
            } catch {
                setLayoutStatus(error.localizedDescription, isError: true)
            }
        }
    }

    // MARK: 应用位置

    private var locationsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            card {
                Text("默认应用位置")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.black.opacity(0.75))
                    .padding(.horizontal, 12)
                    .padding(.top, 9)
                Text("macOS 安装应用的默认文件夹。")
                    .font(.system(size: 11))
                    .foregroundStyle(.black.opacity(0.4))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                ForEach(AppScanner.searchRoots, id: \.self) { root in
                    divider
                    Text(displayPath(root))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.black.opacity(0.8))
                        .padding(.horizontal, 12)
                        .frame(height: 30, alignment: .center)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            card {
                Text("其他应用位置")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.black.opacity(0.75))
                    .padding(.horizontal, 12)
                    .padding(.top, 9)
                Text("添加自定义文件夹，以包含安装在其他位置的应用，例如外置硬盘或自定义目录。")
                    .font(.system(size: 11))
                    .foregroundStyle(.black.opacity(0.4))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .fixedSize(horizontal: false, vertical: true)

                if model.settings.extraFolders.isEmpty {
                    Text("暂无文件夹")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.black.opacity(0.35))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                } else {
                    ForEach(model.settings.extraFolders.indices, id: \.self) { i in
                        divider
                        Button {
                            selectedExtra = selectedExtra == i ? nil : i
                        } label: {
                            Text(displayPath(model.settings.extraFolders[i]))
                                .font(.system(size: 12.5))
                                .foregroundStyle(.black.opacity(0.8))
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .frame(height: 30, alignment: .center)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(selectedExtra == i
                                            ? DesignTokens.settingsAccent.opacity(0.14)
                                            : .clear)
                        }
                        .buttonStyle(SettingsButtonStyle(hoverFill: DesignTokens.hoverFill, radius: 5))
                        .accessibilityLabel("应用位置：\(displayPath(model.settings.extraFolders[i]))")
                    }
                }

                divider
                HStack(spacing: 6) {
                    plusMinus("+", enabled: true) { addExtraFolder() }
                    plusMinus("–", enabled: selectedExtra != nil) { removeSelectedExtra() }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.045))

                divider
                actionRow(title: "重新扫描应用", systemImage: "arrow.clockwise") {
                    model.scanApps()
                }
            }
        }
    }

    // MARK: 已隐藏 App

    private var hiddenPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            card {
                toggleRow(title: "自动隐藏不常用 App",
                          subtitle: "长期没有打开过的 App 会被收进隐藏区，随时可以恢复",
                          isOn: $model.settings.autoHideUnused)
                if model.settings.autoHideUnused {
                    divider
                    sliderRow(title: "闲置天数",
                              valueText: "\(model.settings.autoHideDays) 天",
                              value: intBinding(\.autoHideDays, range: 7...180),
                              range: 7...180, step: 1)
                }
            }

            card {
                if model.hiddenTiles.isEmpty {
                    Text("没有被隐藏的 App")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.black.opacity(0.35))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 22)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 14) {
                        ForEach(model.hiddenTiles) { tile in
                            HiddenRestoreCell(tile: tile)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    // MARK: 关于

    private var aboutPage: some View {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return VStack(alignment: .leading, spacing: 14) {
            card {
                HStack {
                    Text("版本")
                        .font(.system(size: 13))
                        .foregroundStyle(.black.opacity(0.85))
                    Spacer()
                    Text("\(version) (\(build))")
                        .font(.system(size: 12.5).monospacedDigit())
                        .foregroundStyle(.black.opacity(0.5))
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                divider
                HStack {
                    Text("设置数据")
                        .font(.system(size: 13))
                        .foregroundStyle(.black.opacity(0.85))
                    Spacer()
                    Text("state.json")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.black.opacity(0.5))
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
            }
            Text(AppBrand.aboutFooter)
                .font(.system(size: 11.5))
                .foregroundStyle(.black.opacity(0.4))
        }
    }

    // MARK: - Row builders

    /// Wraps rows in the rounded gray card used across every page.
    @ViewBuilder
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous)
                .fill(DesignTokens.settingsCard))
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous))
    }

    private var divider: some View {
        Rectangle()
            .fill(DesignTokens.settingsHairline)
            .frame(height: DesignTokens.hairline)
    }

    private func header(title: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: DesignTokens.rowTitle, weight: .medium))
                .foregroundStyle(DesignTokens.settingsText)
            Text(caption)
                .font(.system(size: DesignTokens.caption))
                .foregroundStyle(DesignTokens.settingsMuted)
        }
    }

    private func toggleRow(title: String, subtitle: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: DesignTokens.rowTitle))
                    .foregroundStyle(DesignTokens.settingsText)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: DesignTokens.caption))
                        .foregroundStyle(DesignTokens.settingsMuted)
                }
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(title)
                .accessibilityValue(isOn.wrappedValue ? "开" : "关")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, subtitle == nil ? 0 : 7)
        .frame(minHeight: 36)
    }

    /// Two real NSGlassEffectView styles, not a cosmetic toggle.
    private func segmentedRow(title: String, selection: Binding<SearchGlassStyle>) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: DesignTokens.rowTitle))
                .foregroundStyle(DesignTokens.settingsText)
                .fixedSize()
                .lineLimit(1)
            Spacer(minLength: 8)
            Picker("", selection: selection) {
                ForEach(SearchGlassStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(DesignTokens.settingsAccent)
            .frame(width: 240)
            .accessibilityLabel(title)
            .accessibilityValue(selection.wrappedValue.label)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 46)
    }

    /// Per-edge inset slider. Copy-modify-write on `settings.gridInsets` so
    /// the @Published setter always fires and SwiftUI re-lays out the grid.
    /// Also refreshes the legacy single-value mirror for older builds.
    private func insetBinding(_ side: GridInsetSide) -> Binding<Double> {
        Binding(
            get: {
                switch side {
                case .top: return model.settings.gridInsets.top
                case .bottom: return model.settings.gridInsets.bottom
                case .left: return model.settings.gridInsets.left
                case .right: return model.settings.gridInsets.right
                }
            },
            set: { newValue in
                var edges = model.settings.gridInsets
                edges.set(side, newValue)
                model.settings.gridInsets = edges
                model.settings.gridInset = edges.average
            }
        )
    }

    private func insetPointsText(_ side: GridInsetSide) -> String {
        let e = model.gridInsetsPoints
        switch side {
        case .top: return "\(Int(e.top))pt"
        case .bottom: return "\(Int(e.bottom))pt"
        case .left: return "\(Int(e.left))pt"
        case .right: return "\(Int(e.right))pt"
        }
    }

    private func sliderRow(title: String,
                           valueText: String,
                           value: Binding<Double>,
                           range: ClosedRange<Double>,
                           step: Double = 0,
                           under: [String] = [],
                           controlWidth: CGFloat = 280) -> some View {
        // Fixed frames must never exceed what the title side leaves free or
        // the title collapses to zero width (double-column rows).
        let sliderWidth = min(controlWidth - 48, 240)
        return HStack(spacing: 12) {
            Text(title)
                .font(.system(size: DesignTokens.rowTitle))
                .foregroundStyle(DesignTokens.settingsText)
                .fixedSize()
                .lineLimit(1)
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Group {
                        if step > 0 {
                            Slider(value: value, in: range, step: step)
                        } else {
                            Slider(value: value, in: range)
                        }
                    }
                    .tint(DesignTokens.settingsAccent)
                    .frame(width: sliderWidth)
                    .accessibilityLabel(title)
                    .accessibilityValue(valueText)
                    Text(valueText)
                        .font(.system(size: DesignTokens.caption).monospacedDigit())
                        .foregroundStyle(DesignTokens.settingsMuted)
                        .fixedSize()
                        .lineLimit(1)
                }
                if !under.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(under.indices, id: \.self) { i in
                            Text(under[i])
                                .font(.system(size: DesignTokens.micro))
                                .foregroundStyle(DesignTokens.settingsFaint)
                                .padding(.horizontal, under.count <= 3 ? 6 : 8)
                            if i < under.count - 1 { Spacer(minLength: 0) }
                        }
                        .padding(.leading, 6)
                    }
                    .frame(width: sliderWidth, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 46)
    }

    private func actionRow(title: String, systemImage: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: DesignTokens.rowTitle))
                    .foregroundStyle(destructive ? DesignTokens.settingsDanger : DesignTokens.settingsText)
                Spacer()
                Image(systemName: systemImage)
                    .font(.system(size: DesignTokens.caption))
                    .foregroundStyle(DesignTokens.settingsFaint)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsButtonStyle())
        .accessibilityLabel(title)
    }

    /// Layout tools row: title + explanatory subtitle on the left, a discrete
    /// action button on the right. Follows the same card/typography tokens as
    /// the rest of the settings pane.
    private func actionRowWithButton(title: String,
                                     subtitle: String,
                                     buttonTitle: String,
                                     destructive: Bool = false,
                                     action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: DesignTokens.rowTitle))
                    .foregroundStyle(DesignTokens.settingsText)
                Text(subtitle)
                    .font(.system(size: DesignTokens.caption))
                    .foregroundStyle(DesignTokens.settingsMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action: action) {
                Text(buttonTitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(destructive
                        ? DesignTokens.settingsDanger
                        : Color.black.opacity(0.7))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: DesignTokens.controlRadius, style: .continuous)
                        .fill(Color.black.opacity(0.06)))
            }
            .buttonStyle(SettingsButtonStyle())
            .accessibilityLabel("\(title)：\(buttonTitle)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 50)
    }

    private func plusMinus(_ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(enabled ? .black.opacity(0.6) : .black.opacity(0.2))
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(.black.opacity(enabled ? 0.15 : 0.08), lineWidth: DesignTokens.hairline))
        }
        .buttonStyle(SettingsButtonStyle(hoverFill: Color.clear))
        .accessibilityLabel(label == "+" ? "添加应用位置" : "移除选中的应用位置")
        .disabled(!enabled)
    }

    private func displayPath(_ path: String) -> String {
        var text = path.hasPrefix("/") ? path : path + "/"
        text = text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        return text
    }

    // MARK: - Extra folders

    private func addExtraFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "添加"
        panel.message = "选择一个包含 .app 文件的文件夹"
        FilePanels.prepare(panel)
        // Same rule as every other picker: runModal() drops the panel back to
        // level 8, below the level-19 launcher and level-26 menu cover, so the
        // button appears to do nothing. begin() preserves the armed level.
        panel.begin { response in
            FilePanels.release()
            guard response == .OK, let url = panel.url else { return }
            let path = url.path
            guard !model.settings.extraFolders.contains(path) else { return }
            model.settings.extraFolders.append(path)
            selectedExtra = model.settings.extraFolders.count - 1
        }
    }

    private func removeSelectedExtra() {
        guard let index = selectedExtra, model.settings.extraFolders.indices.contains(index) else { return }
        model.settings.extraFolders.remove(at: index)
        selectedExtra = nil
    }

    private func intBinding(_ keyPath: WritableKeyPath<Settings, Int>, range: ClosedRange<Int>) -> Binding<Double> {
        Binding(
            get: { Double(model.settings[keyPath: keyPath]) },
            set: { model.settings[keyPath: keyPath] = min(max(Int($0.rounded()), range.lowerBound), range.upperBound) }
        )
    }
}

/// Light grid cell used on the 已隐藏 App page; clicking restores the app.
private struct HiddenRestoreCell: View {
    @EnvironmentObject var model: LauncherModel
    let tile: Tile

    private var tileName: String {
        if let folder = tile.folder { return folder.name }
        if let id = tile.bundleID { return model.appsByID[id]?.name ?? id }
        return tile.id
    }

    var body: some View {
        Button {
            model.unhide(tileID: tile.id)
            model.persist()
        } label: {
            VStack(spacing: 5) {
                TileIcon(tile: tile, size: 44)
                Text(tileName)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.black.opacity(0.6))
                    .lineLimit(1)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.black.opacity(0.07), lineWidth: 0.7))
        }
        .buttonStyle(.plain)
    }
}
