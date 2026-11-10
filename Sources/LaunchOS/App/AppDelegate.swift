import AppKit
import QuartzCore
import SwiftUI

final class LauncherWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: LauncherWindow?
    private var statusItem: NSStatusItem?
    /// Title shows the live launcher chord, so it must follow Settings.
    private var launcherMenuItem: NSMenuItem?
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    /// Dedicated wheel consumer for an open folder. Registered *after* the
    /// pager monitor: that one deliberately returns the event unchanged while
    /// a panel is on top, and this one then claims it for the folder's own
    /// 3 × 3 pages instead of letting it vanish into a nonexistent ScrollView.
    private var folderScrollMonitor: Any?
    private let model = LauncherModel.shared
    private let launchStart = ProcessInfo.processInfo.systemUptime

    /// Any `--` launch argument or LAUNCHOS_DEBUG means a diagnostic / demo
    /// run. Those must keep the process alive until their own harness ends;
    /// exit-on-hide would otherwise kill the probe in the middle of a log.
    private var diagnosticMode: Bool {
        ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--") })
            || ProcessInfo.processInfo.environment["LAUNCHOS_DEBUG"] == "1"
    }

    private var shouldExitOnHide: Bool {
        ResidencyPolicy.shouldExitOnHide(
            settings: model.settings,
            diagnosticMode: diagnosticMode,
            quitProbe: ProcessInfo.processInfo.arguments.contains("--quit-probe"))
    }

    /// Info.plist declares LSUIElement, so LaunchServices starts us as
    /// `.accessory` and never creates a Dock tile: no icon bounce, no running
    /// indicator, no foreground-app menu bar. This is the same shape as
    /// BuhoLaunchpad (launcher is LSBackgroundOnly, window host is LSUIElement).
    /// The process normally stays resident so the Carbon start key survives a
    /// hide; `quitOnHide` remains a reversible opt-out for a cold start every
    /// time. The env var / Settings switch is the A-B and rollback path.
    private var wantsDockTile: Bool {
        if ProcessInfo.processInfo.environment["LAUNCHOS_REGULAR"] == "1" { return true }
        return model.settings.showInDock
    }

    func applyDockPresence() {
        NSApp.setActivationPolicy(wantsDockTile ? .regular : .accessory)
        log("activationPolicy=\(NSRunningApplication.current.activationPolicy.rawValue) wantsDockTile=\(wantsDockTile)")
    }

    /// `applicationShouldHandleReopen` (below) already routes Dock clicks to
    /// show/hide. With the process now resident that path runs on every click
    /// instead of only on a cold start, so `--residency-probe` exercises it
    /// explicitly after a hide.

    /// Diagnostic accessor for `--residency-probe`. The real window stays
    /// private; the probe observes the actual show/hide entry points and the
    /// very same content layer that the reveal animation touches.
    var probeWindow: NSWindow? { window }

    // MARK: - Lifecycle

    private let debugEnabled = ProcessInfo.processInfo.arguments.contains("--self-test")
        || ProcessInfo.processInfo.environment["LAUNCHOS_DEBUG"] == "1"

    private func log(_ message: String) {
        guard debugEnabled else { return }
        let line = "[\(Date().formatted(date: .omitted, time: .standard))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/launchos-life.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("didFinishLaunching")
        // Do NOT force .regular here: Info.plist already made us .accessory.
        // Applying the persisted preference after bootstrap() (which loads
        // state.json) keeps the "show in Dock" switch honest on cold start.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        buildMenu()
        buildStatusItem()
        buildWindow()
        buildMenuCover()
        installMonitors()

        GlobalHotKey.shared.handler = { [weak self] in
            self?.toggleLauncher()
        }

        model.onHide = { [weak self] in
            self?.hideLauncher()
        }
        model.onHotKeysChanged = { [weak self] in
            self?.applyLauncherHotKey()
        }
        model.bootstrap()
        // Registration must happen after bootstrap(): the chord now comes from
        // the persisted Settings instead of a compile-time constant.
        applyLauncherHotKey()
        LayoutSync.shared.attach(model: model)
        applyDockPresence()

        showLauncher()
        launchedAt = Date()
        WheelDiagnostics.reset()
        runDemoIfNeeded()
        startProbeIfNeeded()
        startBrandProbeIfNeeded()
        startAppearanceProbeIfNeeded()
        startSearchHotKeyProbeIfNeeded()
        startLauncherHotKeyProbeIfNeeded()
        startResidencyProbeIfNeeded()
        startWheelProbeIfNeeded()
        startLayoutProbeIfNeeded()
        startICloudSyncProbeIfNeeded()
        startSyncFolderProbeIfNeeded()
        startPickerPathProbeIfNeeded()
        startMergeProbeIfNeeded()
        startWallpaperProbeIfNeeded()
        startLayoutToolsProbeIfNeeded()
        startEdgeInsetProbeIfNeeded()
        startQuitProbeIfNeeded()
        startDockProbeIfNeeded()
        startSettingsScrollProbeIfNeeded()
        startMenuBarProbeIfNeeded()
        startSearchGlassProbeIfNeeded()
        startFolderGlassProbeIfNeeded()
        startFolderIconGlassProbeIfNeeded()
        startFolderInteractionProbeIfNeeded()
        startWallpaperPickerProbeIfNeeded()
        startSearchQueryProbeIfNeeded()
        startSearchRealUseProbeIfNeeded()
        startSearchIMEProbeIfNeeded()
        startUIAuditProbeIfNeeded()
        PanelVisibilityProbe.startIfNeeded(model: model, window: window, cover: menuCover)
    }

    /// Diagnostic: `LaunchOS --ui-audit-probe` measures the three things a
    /// screenshot cannot: (1) whether the icon-size slider actually changes
    /// geometry and whether a tile overflows its cell, (2) which source an
    /// app label comes from, and (3) how well the search index matches Chinese,
    /// pinyin and initials. Off by default; quits by itself.
    private func startUIAuditProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--ui-audit-probe") else { return }
        let logPath = "/tmp/launchos-ui-audit.log"
        try? FileManager.default.removeItem(atPath: logPath)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            self.model.settingsOpen = false
            self.model.hiddenOpen = false
            self.model.openFolderID = nil

            func isCJK(_ s: String) -> Bool {
                s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
            }
            func f(_ v: CGFloat) -> String { String(format: "%.1f", v) }
            var lines = [
                "PROBE UI audit",
                "system=\(ProcessInfo.processInfo.operatingSystemVersionString)",
                "active=\(NSApp.isActive) keyWindow=\(self.window?.isKeyWindow ?? false)"
            ]

            // 1. Geometry / icon scale. Tile body = icon frame (+18) + spacing
            //    6 + label 24. Anything above cellH overlaps the next row.
            let originalScale = self.model.settings.iconScale
            let base = self.model.metrics
            lines.append("GEOM area=\(f(base.size.width))x\(f(base.size.height))"
                + " cols=\(base.cols) rows=\(base.rows)"
                + " cellW=\(f(base.cellW)) cellH=\(f(base.cellH))"
                + " insets=T\(f(base.insets.top)) L\(f(base.insets.left)) B\(f(base.insets.bottom)) R\(f(base.insets.right))"
                + " showsLabels=\(self.model.settings.showLabels)")
            for s in [0.78, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4] {
                self.model.settings.iconScale = s
                let m = self.model.metrics
                let content = m.iconSize + 18 + 6 + (self.model.settings.showLabels ? 24 : 0)
                lines.append("SWEEP scale=\(String(format: "%.2f", s))"
                    + " iconSize=\(f(m.iconSize)) hitHalf=\(f(m.iconHitHalf))"
                    + " tileContent=\(f(content)) cellH=\(f(m.cellH))"
                    + " overflow=\(f(content - m.cellH))")
            }
            self.model.settings.iconScale = originalScale

            // 1b. The user's real configuration is 9x7, which has much less
            //     vertical headroom than the default 7x5 measured above.
            let originalCols = self.model.settings.columns
            let originalRows = self.model.settings.rows
            self.model.settings.columns = 9
            self.model.settings.rows = 7
            let real = self.model.metrics
            lines.append("REAL9x7 cellW=\(f(real.cellW)) cellH=\(f(real.cellH))")
            for s in [0.78, 1.0, 1.2, 1.3, 1.4] {
                self.model.settings.iconScale = s
                let m = self.model.metrics
                let content = m.iconSize + 18 + 6 + (self.model.settings.showLabels ? 24 : 0)
                lines.append("REALSWEEP scale=\(String(format: "%.2f", s))"
                    + " iconSize=\(f(m.iconSize)) overflow=\(f(content - m.cellH))")
            }
            self.model.settings.iconScale = originalScale
            self.model.settings.columns = originalCols
            self.model.settings.rows = originalRows

            // 2. App names: what the grid renders vs every available source.
            let apps = self.model.visibleApps
            let cjkNames = apps.filter { isCJK($0.name) }
            lines.append("NAMES total=\(apps.count) renderedCJK=\(cjkNames.count)"
                + " renderedCJKList=[\(cjkNames.prefix(20).map(\.name).joined(separator: "|"))]")
            var localizedCJK = 0, displayCJK = 0, rawCJK = 0, differs = 0
            for app in apps {
                guard let bundle = Bundle(url: app.url), let info = bundle.infoDictionary else { continue }
                let raw = (info["CFBundleDisplayName"] as? String)
                    ?? (info["CFBundleName"] as? String) ?? ""
                let loc = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? ""
                let disp = FileManager.default.displayName(atPath: app.path)
                if isCJK(raw) { rawCJK += 1 }
                if isCJK(loc) { localizedCJK += 1 }
                if isCJK(disp) { displayCJK += 1 }
                if loc != raw || disp != raw { differs += 1 }
                if isCJK(raw) != isCJK(disp), differs <= 30 {
                    lines.append("NAME file=\(app.url.lastPathComponent)"
                        + " rendered=\(app.name.debugDescription)"
                        + " raw=\(raw.debugDescription)"
                        + " localized=\(loc.debugDescription)"
                        + " display=\(disp.debugDescription)"
                        + " pinyin=\(app.pinyin.debugDescription)")
                }
            }
            lines.append("NAME_COUNTS rawCJK=\(rawCJK) localizedCJK=\(localizedCJK)"
                + " displayCJK=\(displayCJK) differs=\(differs)")

            // 3. Search quality over Chinese, full pinyin and initials.
            self.model.closeSearch()
            for q in ["广告", "guanggao", "gg", "wy", "wangyi", "网易", "邮箱",
                      "mailmaster", "qianwen", "千问", "千问", "wyyxds", "wechat",
                      "微信", "hid", "hiddify", "app.hiddify.com", "chrome", ""] {
                self.model.setSearchText(q)
                let r = self.model.searchResults
                lines.append("SEARCH q=\(q.debugDescription) count=\(r.count)"
                    + " first=\(r.first?.name ?? "-")"
                    + " names=[\(r.prefix(5).map(\.name).joined(separator: "|"))]")
                if q == "gg" || q == "chrome" {
                    for app in r.prefix(6) {
                        lines.append("HIT q=\(q) name=\(app.name.debugDescription)"
                            + " bundleID=\(app.bundleID.debugDescription)"
                            + " aliases=\(app.aliases.debugDescription)"
                            + " pinyin=\(app.pinyin.debugDescription)"
                            + " initials=\(app.pinyinInitials.debugDescription)"
                            + " romanized=\(app.romanizedAliases.debugDescription)"
                            + " romanizedInitials=\(app.romanizedInitials.debugDescription)")
                    }
                }
            }
            self.model.setSearchText("")
            self.model.closeSearch()

            // 4. Search panel proportions vs the main grid.
            let panelWidth = min(900, max(360, base.size.width - 80))
            let resultIcon = min(78, max(52, self.model.metrics.iconSize * 0.46))
            lines.append("PANEL width=\(f(panelWidth)) columns=\(LauncherModel.searchColumns)"
                + " resultIcon=\(f(resultIcon)) resultLabelWidth=\(f(resultIcon + 38))"
                + " rowHeight=\(f(resultIcon + 48))"
                + " gridIcon=\(f(self.model.metrics.iconSize))")
            lines.append("DONE")
            try? (lines.joined(separator: "\n") + "\n")
                .write(toFile: logPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    /// Diagnostic: `LaunchOS --search-glass-probe` opens search and A/B's the
    /// switch. SwiftUI renders glass as CABackdropLayer + SDFPortalLayer rather
    /// than an NSGlassEffectView subclass, so the layer-histogram delta plus a
    /// 1.2 s frame sample on each side is the evidence that it really rendered
    /// and what it costs. Screen capture is disabled in this environment; no
    /// screenshot is attempted. Off by default; quits by itself.
    private func startSearchGlassProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--search-glass-probe") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            self.model.settingsOpen = false
            self.model.hiddenOpen = false
            self.model.openSearch("")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self else { return }
                let s = self.model.settings
                let onTree = self.treeClasses(in: self.window?.contentView)
                var lines = [
                    "PROBE search liquid glass",
                    "system=\(ProcessInfo.processInfo.operatingSystemVersionString)",
                    "glassAvailable=\(SearchGlass.isAvailable) "
                        + "systemHasNSGlassEffectView=\(NSClassFromString("NSGlassEffectView") != nil)",
                    "enabled=\(s.glassEnabled) style=\(s.glassStyle.rawValue) "
                        + "tint=\(s.glassTint) radius=\(s.glassRadius) scrim=\(s.glassScrim)",
                    "searchOpen=\(self.model.searchOpen) results=\(self.model.searchResults.count)",
                    "glassOn layers=\(self.glassLayerCounts(onTree))",
                    "glassOn tree=\(self.classHistogram(onTree))"
                ]
                self.sampleFrames(for: 1.2) { onFrames in
                    lines.append("glassOn frames \(onFrames)")
                    self.model.settings.glassEnabled = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                        guard let self else { return }
                        let offTree = self.treeClasses(in: self.window?.contentView)
                        lines.append("glassOff layers=\(self.glassLayerCounts(offTree))")
                        self.sampleFrames(for: 1.2) { offFrames in
                            lines.append("glassOff frames \(offFrames)")
                            self.model.settings.glassEnabled = true
                            lines.append("DONE")
                            try? (lines.joined(separator: "\n") + "\n")
                                .write(toFile: "/tmp/launchos-search-glass.log", atomically: true, encoding: .utf8)
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
        }
    }

    /// Diagnostic: `LaunchOS --folder-glass-probe` opens a REAL folder through
    /// `model.openFolderID` (the same entry point a click uses) and A/B's the
    /// folder glass switch. SwiftUI renders glass as CABackdropLayer +
    /// SDFPortalLayer, so the layer-histogram delta is the evidence that the
    /// panel really changed surface, not just that a setting was written.
    /// Off by default; quits by itself. No screenshot is attempted.
    private func startFolderGlassProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--folder-glass-probe") else { return }
        let log = "/tmp/launchos-folder-glass.log"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            self.model.settingsOpen = false
            self.model.hiddenOpen = false
            self.model.searchOpen = false
            guard let folder = self.model.allFolders.first else {
                try? "PROBE folder glass\nFAIL no folder in state\nDONE\n"
                    .write(toFile: log, atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            // Real entry point: PanelLayer sees openFolderID and renders
            // FolderOverlay, which now owns FolderGlassPanel.
            self.model.openFolderID = folder.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self else { return }
                let s = self.model.settings
                let onTree = self.treeClasses(in: self.window?.contentView)
                let onCounts = self.glassLayerCounts(onTree)
                var lines = [
                    "PROBE folder liquid glass",
                    "system=\(ProcessInfo.processInfo.operatingSystemVersionString)",
                    "glassAvailable=\(SearchGlass.isAvailable)",
                    "folderID=\(folder.id) members=\(folder.bundleIDs.count) "
                        + "openFolderID=\(self.model.openFolderID ?? "nil") "
                        + "resolved=\(self.model.folder(folder.id) != nil)",
                    "enabled=\(s.glassEnabled) style=\(s.glassStyle.rawValue) "
                        + "tint=\(s.glassTint) radius=\(s.glassRadius) scrim=\(s.glassScrim)",
                    "glassOn layers=\(onCounts)",
                    "glassOn tree=\(self.classHistogram(onTree))"
                ]
                self.sampleFrames(for: 1.0) { onFrames in
                    lines.append("glassOn frames \(onFrames)")
                    self.model.settings.glassEnabled = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self else { return }
                        let offTree = self.treeClasses(in: self.window?.contentView)
                        let offCounts = self.glassLayerCounts(offTree)
                        lines.append("glassOff layers=\(offCounts)")
                        self.sampleFrames(for: 1.0) { offFrames in
                            lines.append("glassOff frames \(offFrames)")
                            let backdropOn = onTree.filter { $0.contains("CABackdropLayer") }.count
                            let backdropOff = offTree.filter { $0.contains("CABackdropLayer") }.count
                            let portalOn = onTree.filter { $0.contains("SDFPortalLayer") }.count
                            let portalOff = offTree.filter { $0.contains("SDFPortalLayer") }.count
                            lines.append("A/B backdrop \(backdropOn)->\(backdropOff) portal \(portalOn)->\(portalOff)")
                            // A PASS needs a real drop in glass layers on the
                            // same folder, otherwise an always-true check
                            // would hide a modifier wired to the wrong key.
                            let glassDelta = backdropOn > backdropOff || portalOn > portalOff
                            lines.append(glassDelta ? "A/B PASS" : "A/B FAIL glass layers did not change")
                            // Parameters must reach the rendered description.
                            var tuned = self.model.settings
                            tuned.glassStyle = .clear
                            tuned.glassTint = 0.55
                            tuned.glassRadius = 30
                            tuned.glassScrim = 0.44
                            let snap = FolderGlassSnapshot(settings: tuned)
                            let tunedOK = snap.style == .clear && snap.tintPercent == 55
                                && snap.radius == 30 && snap.scrimPercent == 44
                            lines.append(tunedOK ? "params PASS \(snap.readout)"
                                         : "params FAIL \(snap.readout)")
                            // Real close path still works while the glass is off.
                            self.model.openFolderID = nil
                            lines.append(self.model.openFolderID == nil
                                         ? "close PASS" : "close FAIL")
                            self.model.settings.glassEnabled = true
                            lines.append(glassDelta && tunedOK ? "PASS" : "FAIL")
                            lines.append("DONE")
                            try? (lines.joined(separator: "\n") + "\n")
                                .write(toFile: log, atomically: true, encoding: .utf8)
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
        }
    }

    /// Diagnostic: `LaunchOS --folder-icon-glass-probe` keeps the GRID visible
    /// (no open folder, no search) and A/B's the folder-glass switch on the
    /// collapsed folder tiles. Those tiles live inside PageSlot.drawingGroup(),
    /// so this is the only way to learn whether real glass renders through the
    /// paging raster and what it costs per frame. Off by default; quits by
    /// itself. No screenshot is attempted.
    private func startFolderIconGlassProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--folder-icon-glass-probe") else { return }
        let log = "/tmp/launchos-folder-icon-glass.log"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            self.model.settingsOpen = false
            self.model.hiddenOpen = false
            self.model.searchOpen = false
            self.model.openFolderID = nil
            let folders = self.model.allFolders
            guard !folders.isEmpty else {
                try? "PROBE folder icon glass\nFAIL no folder in state\nDONE\n"
                    .write(toFile: log, atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            let iconSize = self.model.metrics.iconSize
            let s = self.model.settings
            let icon0 = FolderIconGlass(settings: s, size: iconSize)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                let onTree = self.treeClasses(in: self.window?.contentView)
                var lines = [
                    "PROBE collapsed folder icon liquid glass",
                    "system=\(ProcessInfo.processInfo.operatingSystemVersionString)",
                    "glassAvailable=\(SearchGlass.isAvailable) "
                        + "plate=\(ProbeConfig.folderIconPlate) "
                        + "noRaster=\(ProbeConfig.noRaster) "
                        + "noGlass=\(ProbeConfig.folderIconNoGlass)",
                    "folders=\(folders.count) iconSize=\(Int(iconSize.rounded())) "
                        + "pages=\(self.model.pageCount) openFolderID=\(self.model.openFolderID ?? "nil")",
                    "enabled=\(s.glassEnabled) style=\(s.glassStyle.rawValue) "
                        + "tint=\(s.glassTint) radius=\(s.glassRadius) scrim=\(s.glassScrim)",
                    "iconSnapshot=\(icon0.readout)",
                    "glassOn layers=\(self.glassLayerCounts(onTree))",
                    "glassOn tree=\(self.classHistogram(onTree))"
                ]
                self.sampleFrames(for: 1.0) { onFrames in
                    lines.append("glassOn frames \(onFrames)")
                    self.model.settings.glassEnabled = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self else { return }
                        let offTree = self.treeClasses(in: self.window?.contentView)
                        let iconOff = FolderIconGlass(settings: self.model.settings, size: iconSize)
                        lines.append("glassOff layers=\(self.glassLayerCounts(offTree))")
                        lines.append("iconOff mode=\(iconOff.modeText) radius=\(Int(iconOff.cornerRadius.rounded()))pt")
                        self.sampleFrames(for: 1.0) { offFrames in
                            lines.append("glassOff frames \(offFrames)")
                            let backdropOn = onTree.filter { $0.contains("CABackdropLayer") }.count
                            let backdropOff = offTree.filter { $0.contains("CABackdropLayer") }.count
                            let portalOn = onTree.filter { $0.contains("SDFPortalLayer") }.count
                            let portalOff = offTree.filter { $0.contains("SDFPortalLayer") }.count
                            lines.append("A/B backdrop \(backdropOn)->\(backdropOff) portal \(portalOn)->\(portalOff)")
                            // A PASS needs a real glass-layer delta on the same
                            // grid. If drawingGroup flattens the effect away,
                            // the probe fails instead of silently claiming a
                            // visual change that never reached the screen.
                            let glassDelta = backdropOn > backdropOff || portalOn > portalOff
                            lines.append(glassDelta ? "A/B PASS" : "A/B FAIL glass layers did not change")
                            lines.append(!iconOff.enabled && iconOff.modeText == "原材质"
                                         ? "switch PASS" : "switch FAIL")
                            var tuned = self.model.settings
                            tuned.glassEnabled = true
                            tuned.glassStyle = .clear
                            tuned.glassTint = 0.55
                            tuned.glassRadius = 34
                            tuned.glassScrim = 0.44
                            let t = FolderIconGlass(settings: tuned, size: iconSize)
                            let expected = min(max(iconSize * 0.235
                                                   * CGFloat(34 / Settings.defaultGlassRadius),
                                                   iconSize * 0.10), iconSize * 0.42)
                            let geometryOK = abs(t.cornerRadius - expected) < 0.001
                            lines.append(t.enabled && t.style == .clear && t.tintPercent == 55
                                         && t.radius == 34 && t.scrimPercent == 44 && geometryOK
                                         ? "params PASS \(t.readout)" : "params FAIL \(t.readout)")
                            self.model.settings.glassEnabled = true
                            lines.append(self.model.openFolderID == nil
                                         ? "grid PASS" : "grid FAIL folder stayed open")
                            lines.append(glassDelta && !iconOff.enabled && t.enabled
                                         && geometryOK ? "PASS" : "FAIL")
                            lines.append("DONE")
                            try? (lines.joined(separator: "\n") + "\n")
                                .write(toFile: log, atomically: true, encoding: .utf8)
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
        }
    }

    /// Diagnostic: `LaunchOS --search-query-probe` drives the search field
    /// through several values and records both the model's results and what
    /// `SearchOverlay` actually rendered — with Liquid Glass on and off, plus
    /// a close/reopen cycle. It isolates "the model recomputed" from "SwiftUI
    /// refreshed the results panel". Off by default; writes a log and quits.
    /// Run against an isolated state directory (LAUNCHOS_STATE_DIR) because
    /// the A/B toggles the glass switch on the live settings object.
    private func startSearchQueryProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--search-query-probe") else { return }
        SearchRenderProbe.enabled = true
        let logPath = "/tmp/launchos-search-query.log"
        try? FileManager.default.removeItem(atPath: logPath)
        let originalGlass = model.settings.glassEnabled

        func label(_ s: String) -> String { s.isEmpty ? "<empty>" : s }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            self.model.settingsOpen = false
            self.model.hiddenOpen = false
            self.model.openFolderID = nil
            var lines = [
                "PROBE search query refresh",
                "system=\(ProcessInfo.processInfo.operatingSystemVersionString)",
                "glassAvailable=\(SearchGlass.isAvailable)"
            ]
            let queries = ["", "c", "ca", "we", "zzznotfound", ""]

            // Cold-start input path: the FIRST search is the one the user says
            // works. Drive real text insertion through the field editor to see
            // whether the TextField binding survives the first change.
            self.model.openSearch("")
            try? await Task.sleep(nanoseconds: 500_000_000)
            let coldWindow = self.window
            func responderName(_ w: NSWindow?) -> String {
                (w?.firstResponder).map { String(describing: type(of: $0)) } ?? "nil"
            }
            lines.append("COLD first-open keyWindow=\(coldWindow?.isKeyWindow ?? false)"
                + " fr=\(responderName(coldWindow)) query=\(label(self.model.query))"
                + " glass=\(self.model.settings.glassEnabled)")
            func insertText(_ s: String) -> Bool {
                guard let tv = coldWindow?.firstResponder as? NSTextView else { return false }
                tv.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0))
                return true
            }
            for ch in ["c", "a", "w"] {
                SearchRenderProbe.reset()
                let ok = insertText(ch)
                try? await Task.sleep(nanoseconds: 250_000_000)
                lines.append("COLD insert=\(ch) ok=\(ok)"
                    + " query=\(label(self.model.query))"
                    + " results=\(self.model.searchResults.count)"
                    + " render=[\(SearchRenderProbe.snapshot)]"
                    + " fr=\(responderName(coldWindow))")
            }

            @MainActor func runPass(_ glass: Bool) async {
                self.model.settings.glassEnabled = glass
                self.model.openSearch("")
                lines.append("--- glass=\(glass) ---")
                for (index, q) in queries.enumerated() {
                    SearchRenderProbe.reset()
                    self.model.setSearchText(q)
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    let modelResults = self.model.searchResults
                    let fr = self.window?.firstResponder
                    let tree = self.treeClasses(in: self.window?.contentView)
                    lines.append(
                        "step\(index) set=\(label(q))"
                        + " modelQuery=\(label(self.model.query))"
                        + " modelCount=\(modelResults.count)"
                        + " modelFirst=\(modelResults.first?.name ?? "-")"
                        + " render=[\(SearchRenderProbe.snapshot)]"
                        + " firstResponder=\(fr.map { String(describing: type(of: $0)) } ?? "nil")"
                        + " treeTotal=\(tree.count)"
                        + " backdrop=\(tree.filter { $0.contains("CABackdropLayer") }.count)")
                }
            }

            await runPass(true)
            await runPass(false)

            // Closing and reopening the search is the shape of the user report:
            // the *first* query works, later ones keep the old results.
            self.model.closeSearch()
            try? await Task.sleep(nanoseconds: 400_000_000)
            self.model.openSearch("")
            SearchRenderProbe.reset()
            self.model.setSearchText("we")
            try? await Task.sleep(nanoseconds: 400_000_000)
            lines.append("reopen set=we modelCount=\(self.model.searchResults.count)"
                + " render=[\(SearchRenderProbe.snapshot)]")

            // Every model-level write above refreshed correctly, so the
            // remaining suspect is the real text-input path. Drive real
            // keyDown events through NSApp.sendEvent (which passes the local
            // monitor) and watch model.query after each character.
            self.model.settings.glassEnabled = originalGlass
            let w = self.window
            func frName() -> String {
                (w?.firstResponder).map { String(describing: type(of: $0)) } ?? "nil"
            }
            func postKey(_ chars: String, _ code: UInt16) {
                guard let w else { return }
                guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: w.windowNumber, context: nil, characters: chars,
                    charactersIgnoringModifiers: chars, isARepeat: false,
                    keyCode: code) else { return }
                NSApp.sendEvent(e)
            }

            self.model.closeSearch()
            try? await Task.sleep(nanoseconds: 400_000_000)
            self.model.openSearch("")
            try? await Task.sleep(nanoseconds: 500_000_000)
            lines.append("KEYS first-open keyWindow=\(w?.isKeyWindow ?? false)"
                + " firstResponder=\(frName()) query=\(label(self.model.query))"
                + " glass=\(self.model.settings.glassEnabled)")
            for (ch, code) in [("c", UInt16(8)), ("a", UInt16(0)),
                               ("w", UInt16(13)), ("e", UInt16(14))] {
                postKey(ch, code)
                try? await Task.sleep(nanoseconds: 300_000_000)
                lines.append("KEYS key=\(ch) query=\(label(self.model.query))"
                    + " results=\(self.model.searchResults.count)"
                    + " render=[\(SearchRenderProbe.snapshot)]"
                    + " firstResponder=\(frName())")
            }

            self.model.closeSearch()
            try? await Task.sleep(nanoseconds: 400_000_000)
            self.model.openSearch("")
            try? await Task.sleep(nanoseconds: 500_000_000)
            lines.append("KEYS reopen keyWindow=\(w?.isKeyWindow ?? false)"
                + " firstResponder=\(frName()) query=\(label(self.model.query))")
            postKey("w", 13)
            try? await Task.sleep(nanoseconds: 300_000_000)
            lines.append("KEYS reopen-key=w query=\(label(self.model.query))"
                + " firstResponder=\(frName())")

            if let tv = w?.firstResponder as? NSTextView {
                tv.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
                try? await Task.sleep(nanoseconds: 300_000_000)
                lines.append("KEYS insertText X query=\(label(self.model.query))")
            } else {
                lines.append("KEYS insertText skipped noFieldEditor")
            }

            lines.append("DONE")
            try? (lines.joined(separator: "\n") + "\n")
                .write(toFile: logPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    /// Diagnostic: `LaunchOS --search-realuse-probe` walks the *real* keyboard
    /// path — typing a letter over the icon grid opens search with that letter
    /// already in the field — then keeps typing with human-scale gaps, deletes
    /// and retypes, escapes and reopens, and uses ⌘F. Unlike --search-query-probe
    /// it never writes `model.query` directly. Each step records the model, what
    /// `SearchOverlay` computed, the field editor's own text, and the strings
    /// actually present in the rendered view/layer tree. That separates
    /// "the model changed" from "the screen changed". Off by default.
    private func startSearchRealUseProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--search-realuse-probe") else { return }
        SearchRenderProbe.enabled = true
        let logPath = "/tmp/launchos-search-realuse.log"
        try? FileManager.default.removeItem(atPath: logPath)
        let originalGlass = model.settings.glassEnabled

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            self.model.settingsOpen = false
            self.model.hiddenOpen = false
            self.model.openFolderID = nil
            self.model.closeSearch()
            // A --probe launch is not activated by the window server. Without
            // this the local key monitor's `isKeyWindow` guard drops every
            // event and the whole run is meaningless. Mirror a Dock click.
            NSApp.activate(ignoringOtherApps: true)
            self.window?.makeKeyAndOrderFront(nil)
            try? await Task.sleep(nanoseconds: 350_000_000)

            var lines = [
                "PROBE real-use search",
                "activated=\(NSApp.isActive) key=\(self.window?.isKeyWindow ?? false)",
                "system=\(ProcessInfo.processInfo.operatingSystemVersionString)",
                "glassAvailable=\(SearchGlass.isAvailable)"
            ]

            @MainActor func responderName() -> String {
                (self.window?.firstResponder).map { String(describing: type(of: $0)) } ?? "nil"
            }
            @MainActor func fieldText() -> String {
                (self.window?.firstResponder as? NSTextView)?.string ?? "-"
            }
            @MainActor func postKey(_ chars: String, _ code: UInt16,
                                    _ flags: NSEvent.ModifierFlags = []) {
                guard let w = self.window,
                      let e = NSEvent.keyEvent(with: .keyDown, location: .zero,
                        modifierFlags: flags,
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: w.windowNumber, context: nil,
                        characters: chars, charactersIgnoringModifiers: chars,
                        isARepeat: false, keyCode: code) else { return }
                // Mirror the local monitor exactly. In a headless probe the
                // window never becomes key, so routing purely through
                // NSApp.sendEvent would skip handleKey altogether.
                let panelOpen = self.model.settingsOpen || self.model.hiddenOpen
                    || self.model.openFolderID != nil || self.model.renamingFolderID != nil
                let editing = AppDelegate.isTextEditing(w.firstResponder is NSTextView,
                                                        searchOpen: self.model.searchOpen,
                                                        panelOpen: panelOpen)
                if !self.model.handleKey(e, textEditing: editing) {
                    NSApp.sendEvent(e)
                }
            }
            @MainActor func snap(_ tag: String, _ firstNames: Set<String>) -> String {
                let current = Set(self.model.searchResults.prefix(40).map(\.name))
                let strings = self.visibleStrings(in: self.window?.contentView)
                let shownFirst = Set(strings.filter { firstNames.contains($0) })
                let shownCurrent = Set(strings.filter { current.contains($0) })
                let sample = Array(shownCurrent.union(shownFirst)).sorted().prefix(6)
                return "\(tag)"
                    + " open=\(self.model.searchOpen) gen=\(self.model.searchGeneration)"
                    + " query=\(self.model.query.isEmpty ? "<empty>" : self.model.query)"
                    + " modelCount=\(self.model.searchResults.count)"
                    + " modelFirst=\(self.model.searchResults.first?.name ?? "-")"
                    + " render=[\(SearchRenderProbe.snapshot)]"
                    + " fr=\(responderName()) fieldText=\(fieldText().debugDescription)"
                    + " keyWindow=\(self.window?.isKeyWindow ?? false)"
                    + " visible=\(self.window?.isVisible ?? false)"
                    + " appActive=\(NSApp.isActive)"
                    + " appKey=\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil")"
                    + " visibleStrings=\(strings.count)"
                    + " shownFirst=\(shownFirst.count) shownCurrent=\(shownCurrent.count)"
                    + " shownNames=[\(sample.joined(separator: "|"))]"
            }

            for glass in [true, false] {
                self.model.settings.glassEnabled = glass
                self.model.closeSearch()
                try? await Task.sleep(nanoseconds: 350_000_000)
                lines.append("=== glass=\(glass) ===")
                var firstNames = Set<String>()

                lines.append(snap("grid-before", firstNames))
                postKey("c", 8)                       // grid letter opens search
                try? await Task.sleep(nanoseconds: 40_000_000)
                lines.append(snap("after-c-40ms", firstNames))
                firstNames = Set(self.model.searchResults.prefix(40).map(\.name))

                postKey("a", 0)
                try? await Task.sleep(nanoseconds: 140_000_000)
                lines.append(snap("after-a-140ms", firstNames))

                postKey("w", 13)
                try? await Task.sleep(nanoseconds: 400_000_000)
                lines.append(snap("after-w-400ms", firstNames))

                for _ in 0..<3 { postKey("\u{7f}", 51) }  // delete x3 (NSDeleteCharacter)
                try? await Task.sleep(nanoseconds: 300_000_000)
                lines.append(snap("after-3x-delete", firstNames))

                postKey("w", 13)
                try? await Task.sleep(nanoseconds: 300_000_000)
                lines.append(snap("after-retype-w", firstNames))

                postKey("", 53)                       // esc -> grid
                try? await Task.sleep(nanoseconds: 350_000_000)
                lines.append(snap("after-esc", firstNames))
                postKey("w", 13)                      // second search session
                try? await Task.sleep(nanoseconds: 350_000_000)
                lines.append(snap("reopen-letter-w", firstNames))
                postKey("e", 14)
                try? await Task.sleep(nanoseconds: 350_000_000)
                lines.append(snap("reopen-we", firstNames))

                postKey("", 53)
                try? await Task.sleep(nanoseconds: 350_000_000)
                postKey("f", 3, .command)            // ⌘F path
                try? await Task.sleep(nanoseconds: 350_000_000)
                lines.append(snap("cmdf-open", firstNames))
                postKey("c", 8)
                try? await Task.sleep(nanoseconds: 350_000_000)
                lines.append(snap("cmdf-typed-c", firstNames))
            }

            self.model.settings.glassEnabled = originalGlass
            lines.append("DONE")
            try? (lines.joined(separator: "\n") + "\n")
                .write(toFile: logPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    /// Diagnostic: `LaunchOS --search-ime-probe`. A screenshot showed "广告"
    /// in the field while the only result was Hiddify, so this separates the
    /// visible field text from `model.query` and drives a real IME composition
    /// (setMarkedText -> insertText) rather than plain ASCII keystrokes.
    private func startSearchIMEProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--search-ime-probe") else { return }
        SearchRenderProbe.enabled = true
        let logPath = "/tmp/launchos-search-ime.log"
        try? FileManager.default.removeItem(atPath: logPath)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            self.model.settingsOpen = false
            self.model.hiddenOpen = false
            self.model.openFolderID = nil
            // Match --search-realuse-probe: a --probe launch is not activated
            // by the window server, so make the field editor reachable.
            NSApp.activate(ignoringOtherApps: true)
            self.window?.makeKeyAndOrderFront(nil)
            try? await Task.sleep(nanoseconds: 250_000_000)
            var lines = [
                "PROBE Chinese IME search",
                "system=\(ProcessInfo.processInfo.operatingSystemVersionString)"
            ]

            @MainActor func activeField() -> LaunchOSSearchTextField? {
                self.model.searchField as? LaunchOSSearchTextField
            }
            @MainActor func editor() -> NSTextView? {
                self.window?.firstResponder as? NSTextView
            }
            @MainActor func snap(_ tag: String) -> String {
                let f = activeField()
                let e = editor()
                let r = self.model.searchResults
                return "\(tag)"
                    + " query=\(self.model.query.debugDescription)"
                    + " field=\(f?.stringValue.debugDescription ?? "nil")"
                    + " editor=\(e?.string.debugDescription ?? "nil")"
                    + " marked=\(e?.hasMarkedText() ?? false)"
                    + " count=\(r.count)"
                    + " first=\(r.first?.name ?? "-")"
                    + " fr=\((self.window?.firstResponder).map { String(describing: type(of: $0)) } ?? "nil")"
                    + " render=[\(SearchRenderProbe.snapshot)]"
            }

            // 1. Which query can actually produce a single Hiddify result?
            self.model.closeSearch()
            self.model.openSearch("")
            for q in ["广告", "guanggao", "gg", "g", "hi", "hid", "hiddify", "app.hiddify.com", ""] {
                self.model.setSearchText(q)
                let r = self.model.searchResults
                lines.append("MATCH q=\(q.debugDescription) count=\(r.count)"
                    + " first=\(r.first?.name ?? "-")"
                    + " names=[\(r.prefix(5).map(\.name).joined(separator: "|"))]")
            }
            if let h = self.model.visibleApps.first(where: { $0.name.localizedCaseInsensitiveContains("Hiddify") }) {
                lines.append("APP name=\(h.name.debugDescription) pinyin=\(h.pinyin.debugDescription)"
                    + " bundleID=\(h.bundleID.debugDescription)")
            } else {
                lines.append("APP Hiddify NOT FOUND visible=\(self.model.visibleApps.count)")
            }

            // 2. Replace an existing query with the Chinese "广告" through a
            //    real IME composition, including a SwiftUI recompute mid-IME.
            @MainActor func ime(_ prefix: String, from initial: String) async {
                self.model.closeSearch()
                try? await Task.sleep(nanoseconds: 250_000_000)
                self.model.openSearch(initial)
                try? await Task.sleep(nanoseconds: 500_000_000)
                lines.append(snap("\(prefix)-start"))
                guard let e = editor() else {
                    lines.append("\(prefix)-NO-EDITOR")
                    return
                }
                e.setMarkedText("guanggao",
                                selectedRange: NSRange(location: 8, length: 0),
                                replacementRange: NSRange(location: NSNotFound, length: 0))
                try? await Task.sleep(nanoseconds: 150_000_000)
                lines.append(snap("\(prefix)-marked"))
                self.model.objectWillChange.send()
                try? await Task.sleep(nanoseconds: 150_000_000)
                lines.append(snap("\(prefix)-recompute"))
                e.insertText("广告", replacementRange: NSRange(location: NSNotFound, length: 0))
                try? await Task.sleep(nanoseconds: 350_000_000)
                lines.append(snap("\(prefix)-commit"))
            }

            await ime("A", from: "g")
            await ime("B", from: "")
            await ime("C", from: "hi")

            // 3. A commit that changes the field text without delivering
            //    controlTextDidChange (the shared field editor is driven by
            //    the input method in several macOS IME paths).
            @MainActor func direct(_ prefix: String, from initial: String,
                                   onEditor: Bool) async {
                self.model.closeSearch()
                try? await Task.sleep(nanoseconds: 250_000_000)
                self.model.openSearch(initial)
                try? await Task.sleep(nanoseconds: 450_000_000)
                lines.append(snap("\(prefix)-start"))
                guard let f = activeField() else {
                    lines.append("\(prefix)-NO-FIELD")
                    return
                }
                if onEditor, let tv = f.currentEditor() as? NSTextView {
                    tv.string = "广告"
                } else {
                    f.stringValue = "广告"
                }
                try? await Task.sleep(nanoseconds: 350_000_000)
                lines.append(snap("\(prefix)-after"))
                self.model.objectWillChange.send()
                try? await Task.sleep(nanoseconds: 250_000_000)
                lines.append(snap("\(prefix)-recompute"))
            }
            await direct("D", from: "hid", onEditor: false)
            await direct("E", from: "hid", onEditor: true)

            self.model.closeSearch()
            lines.append("DONE")
            try? (lines.joined(separator: "\n") + "\n")
                .write(toFile: logPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    /// Collects the strings actually attached to rendered AppKit views/layers.
    /// SwiftUI result tiles carry `.accessibilityLabel(app.name)`, so this is a
    /// screenshot-free way to tell which apps are really on screen.
    private func visibleStrings(in view: NSView?) -> [String] {
        guard let view else { return [] }
        var out: [String] = []
        if let label = view.accessibilityLabel(), !label.isEmpty { out.append(label) }
        if let tv = view as? NSTextView { out.append(tv.string) }
        if let tf = view as? NSTextField { out.append(tf.stringValue) }
        if let layer = view.layer { out += self.textStrings(in: layer) }
        for sub in view.subviews { out += self.visibleStrings(in: sub) }
        return out
    }

    private func textStrings(in layer: CALayer) -> [String] {
        var out: [String] = []
        if let text = layer as? CATextLayer {
            if let s = text.string as? String { out.append(s) }
            else if let a = text.string as? NSAttributedString { out.append(a.string) }
        }
        for sub in layer.sublayers ?? [] { out += self.textStrings(in: sub) }
        return out
    }

    private func glassLayerCounts(_ names: [String]) -> String {
        "backdrop=\(names.filter { $0.contains("CABackdropLayer") }.count) "
            + "portal=\(names.filter { $0.contains("SDFPortalLayer") }.count) "
            + "total=\(names.count)"
    }

    private func sampleFrames(for duration: TimeInterval,
                              completion: @escaping (String) -> Void) {
        // CADisplayLink(target:selector:) is iOS-only; macOS builds the link
        // through NSView.displayLink, exactly as FrameProbe does.
        guard let view = self.window?.contentView else {
            completion("n=0 (no host view)")
            return
        }
        let sampler = GlassFrameSampler()
        let link = view.displayLink(target: sampler,
                                    selector: #selector(GlassFrameSampler.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60,
                                                         maximum: 120,
                                                         preferred: 120)
        link.add(to: .main, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            link.invalidate()
            completion(sampler.summary())
        }
    }

    /// CADisplayLink retains its @objc target, so the ticker is a plain
    /// NSObject — same shape as FrameProbe's ProbeTicker.
    private final class GlassFrameSampler: NSObject {
        private var intervals: [Double] = []
        private var previous: CFTimeInterval?

        @objc func tick(_ link: CADisplayLink) {
            if let previous {
                let ms = (link.timestamp - previous) * 1000
                if ms > 0 && ms < 100 { intervals.append(ms) }
            }
            previous = link.timestamp
        }

        func summary() -> String {
            guard !intervals.isEmpty else { return "n=0" }
            let sorted = intervals.sorted()
            let mean = intervals.reduce(0, +) / Double(intervals.count)
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            let jank = intervals.filter { $0 > 25.0 }.count
            return String(format: "n=%d mean=%.2fms p95=%.2fms jank=%d(%.1f%%)",
                          intervals.count, mean, p95, jank,
                          Double(jank) / Double(intervals.count) * 100)
        }
    }

    /// SwiftUI expresses glass as a CALayer rather than an NSView subclass,
    /// so dump both trees. This is diagnostic only: no screenshot is attempted.
    private func treeClasses(in view: NSView?) -> [String] {
        guard let view else { return [] }
        var names = [String(describing: type(of: view))]
        if let layer = view.layer { names += self.layerClasses(layer) }
        for sub in view.subviews { names += self.treeClasses(in: sub) }
        return names
    }

    private func layerClasses(_ layer: CALayer) -> [String] {
        var names = [String(describing: type(of: layer))]
        for sub in layer.sublayers ?? [] { names += self.layerClasses(sub) }
        return names
    }

    private func classHistogram(_ names: [String]) -> String {
        var counts: [String: Int] = [:]
        for name in names { counts[name, default: 0] += 1 }
        return counts
            .sorted { $0.key < $1.key }
            .map { "\($0.key)x\($0.value)" }
            .joined(separator: " | ")
    }

    /// Diagnostic: `LaunchOS --menubar-probe` reports the cover geometry and
    /// the exact quantised backdrop inputs it shares with the main window,
    /// proving the top strip is fed the same wallpaper instead of a solid band.
    /// Screen capture is disabled in headless sessions (screencapture reports
    /// "could not create image from display"), so this probe deliberately does
    /// not attempt a screenshot. Off by default; quits by itself.
    private func startMenuBarProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--menubar-probe") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            let view = self.menuCover?.contentView
            let size = self.model.wallpaper.map {
                "\(Int($0.size.width))x\(Int($0.size.height))"
            } ?? "nil"
            let lines = [
                "PROBE menu bar cover",
                "menuBarHeight=\(self.model.menuBarHeight)",
                "useWallpaper=\(self.model.settings.useWallpaper) wallpaper=\(size)",
                "rawBlur=\(self.model.settings.backgroundBlur) rawDim=\(self.model.settings.backgroundDim)",
                "sharedBlur=\(self.model.quantizedBackdropBlur) sharedDim=\(self.model.quantizedBackdropDim)",
                "coverVisible=\(self.menuCover?.isVisible ?? false) alpha=\(self.menuCover?.alphaValue ?? -1)",
                "coverFrame=\(NSStringFromRect(self.menuCover?.frame ?? .zero))",
                "coverView=\(view.map { String(describing: type(of: $0)) } ?? "nil") "
                    + "bounds=\(NSStringFromRect(view?.bounds ?? .zero)) "
                    + "layer=\(view?.layer != nil) subviews=\(view?.subviews.count ?? 0)",
                "DONE"
            ]
            try? (lines.joined(separator: "\n") + "\n")
                .write(toFile: "/tmp/launchos-menubar-probe.log", atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    /// Diagnostic entry point: `LaunchOS --settings-scroll-probe` verifies the
    /// local scroll monitor hands wheel events back to AppKit whenever a panel
    /// owns the screen. Writes /tmp/launchos-scroll-passthrough.log and quits.
    /// Off by default; never writes the user's state file.
    private func startSettingsScrollProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--settings-scroll-probe") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.model.showSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                var lines = ["PROBE settings scroll passthrough"]
                // Pure branches: a GUI-focused launcher must consume the wheel
                // only when no panel is on top.
                for (tag, visible, key, panel) in [
                    ("normal", true, true, false),
                    ("panel", true, true, true),
                    ("window-hidden", false, true, false),
                    ("window-not-key", true, false, false)
                ] as [(String, Bool, Bool, Bool)] {
                    let consume = Self.pagerShouldConsumeScroll(windowVisible: visible,
                                                                windowKey: key,
                                                                panelOpen: panel)
                    lines.append("branch \(tag) visible=\(visible) key=\(key) panel=\(panel) consume=\(consume)")
                }
                // Real model states, toggled one at a time. A local func would
                // be nonisolated and cannot read @MainActor model state, so
                // the sampling stays inline in the main-actor closure.
                let saved = (self.model.settingsOpen, self.model.hiddenOpen,
                             self.model.searchOpen, self.model.openFolderID)
                let cases: [(String, Bool, Bool, Bool, String?)] = [
                    ("none", false, false, false, nil),
                    ("settings", true, false, false, nil),
                    ("hidden", false, true, false, nil),
                    ("search", false, false, true, nil),
                    ("folder", false, false, false, "probe-folder")
                ]
                for item in cases {
                    self.model.settingsOpen = item.1
                    self.model.hiddenOpen = item.2
                    self.model.searchOpen = item.3
                    self.model.openFolderID = item.4
                    let panel = self.model.scrollBelongsToPanel
                    lines.append("state \(item.0) panel=\(panel) "
                                 + "pureConsume=\(Self.pagerShouldConsumeScroll(windowVisible: true, windowKey: true, panelOpen: panel))")
                }
                self.model.settingsOpen = saved.0; self.model.hiddenOpen = saved.1
                self.model.searchOpen = saved.2; self.model.openFolderID = saved.3
                lines.append("live visible=\(self.window?.isVisible ?? false) "
                             + "key=\(self.window?.isKeyWindow ?? false) "
                             + "panel=\(self.model.scrollBelongsToPanel) "
                             + "consume=\(self.shouldConsumeScrollEvent())")
                lines.append("hostedScrollViews=\(self.countScrollViews(in: self.window?.contentView))")
                lines.append("DONE")
                try? (lines.joined(separator: "\n") + "\n")
                    .write(toFile: "/tmp/launchos-scroll-passthrough.log", atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
        }
    }

    private func countScrollViews(in view: NSView?) -> Int {
        guard let view else { return 0 }
        var total = view is NSScrollView ? 1 : 0
        for sub in view.subviews { total += countScrollViews(in: sub) }
        return total
    }

    /// Diagnostic entry point: `LaunchOS --dock-probe` samples the real
    /// activation policy / key-window state twice, proving the transient-panel
    /// shape never claims a Dock tile and does not auto-hide the launcher.
    /// Pair it with LAUNCHOS_REGULAR=1 for the A/B control.
    private func dockProbeLine(_ tag: String) -> String {
        [
            "tag=\(tag)",
            "policy=\(NSRunningApplication.current.activationPolicy.rawValue)",
            "wantsDockTile=\(wantsDockTile)",
            "nsappActive=\(NSApp.isActive)",
            "keyWindow=\(window?.isKeyWindow ?? false)",
            "visible=\(window?.isVisible ?? false)",
            "shown=\(model.isShown)",
            "statusItem=\(statusItem != nil)"
        ].joined(separator: " ")
    }

    private func startDockProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--dock-probe") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            let first = self.dockProbeLine("t0.7")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self else { return }
                let text = first + "\n" + self.dockProbeLine("t1.6") + "\nDOCK PROBE DONE\n"
                try? text.write(toFile: "/tmp/launchos-dock.log", atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
        }
    }

    /// Diagnostic entry point: `LaunchOS --quit-probe` queues a debounced
    /// state edit, hides the launcher and lets the real exit path run. Always
    /// pair it with an isolated LAUNCHOS_STATE_DIR. Writes the result to
    /// /tmp/launchos-debug.log; the process terminates by itself.
    private func startQuitProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--quit-probe") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.model.runQuitProbe()
            self.model.onHide?()
        }
    }

    /// Diagnostic entry point: `LaunchOS --wallpaper-probe` runs the real
    /// resolver against this Mac's wallpaper configuration, writes the result
    /// to /tmp/launchos-wallpaper.log and quits. Off by default; never reads
    /// or writes the user's state file.
    private func startWallpaperProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--wallpaper-probe") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let result = WallpaperResolver.resolve(customPath: nil, screen: NSScreen.main)
            let size = result.image.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "nil"
            let line = "image=\(result.image != nil) size=\(size) status=\(result.status)\n"
            try? line.write(toFile: "/tmp/launchos-wallpaper.log", atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    /// Diagnostic: `LaunchOS --wallpaper-picker-probe` exercises the whole
    /// "change wallpaper" chain against an isolated state dir: picker window
    /// ordering, then apply path -> decode -> persist -> restore. Screen
    /// capture is unavailable in this session, so window levels and the
    /// decoded NSImage are the evidence. Off by default; writes
    /// /tmp/launchos-wallpaper-picker.log and quits.
    private func startWallpaperPickerProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--wallpaper-picker-probe") else { return }
        var lines: [String] = ["PROBE wallpaper picker"]

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            self.model.settingsOpen = true
            self.model.settingsPage = .appearance
            let testURL = URL(fileURLWithPath: "/tmp/launchos-probe-wallpaper.png")
            self.writeProbeWallpaper(to: testURL)
            let before = self.model.wallpaper.map {
                "\(Int($0.size.width))x\(Int($0.size.height))"
            } ?? "nil"
            lines.append("before image=\(before) status=\(self.model.wallpaperStatus) "
                         + "path=\(self.model.settings.wallpaperPath ?? "nil")")
            self.model.applyWallpaperPath(testURL)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self else { return }
                let after = self.model.wallpaper.map {
                    "\(Int($0.size.width))x\(Int($0.size.height))"
                } ?? "nil"
                lines.append("after image=\(after) status=\(self.model.wallpaperStatus) "
                             + "path=\(self.model.settings.wallpaperPath ?? "nil")")
                lines.append("applySwitched=\(after == "120x80")")
                self.model.flush()
                let dir = ProcessInfo.processInfo.environment["LAUNCHOS_STATE_DIR"]
                    ?? (NSHomeDirectory() + "/Library/Application Support/com.vex.launchos")
                let data = try? Data(contentsOf: URL(fileURLWithPath: dir + "/state.json"))
                let json = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
                let saved = (json?["settings"] as? [String: Any])?["wallpaperPath"] as? String
                lines.append("persistedPath=\(saved ?? "nil") persistedOK=\(saved == testURL.path)")
                self.model.clearWallpaperPath()

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                    guard let self else { return }
                    let restoredSize = self.model.wallpaper.map {
                        "\(Int($0.size.width))x\(Int($0.size.height))"
                    } ?? "nil"
                    lines.append("restored path=\(self.model.settings.wallpaperPath ?? "nil") "
                                 + "status=\(self.model.wallpaperStatus) image=\(restoredSize)")
                    let panel = FilePanels.makeWallpaperPanel()
                    FilePanels.prepare(panel)
                    panel.begin { _ in FilePanels.release() }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                        guard let self else { return }
                        let mainLevel = self.window?.level.rawValue ?? -1
                        let coverLevel = self.menuCover?.level.rawValue ?? -1
                        let panelLevel = panel.level.rawValue
                        lines.append("mainLevel=\(mainLevel) coverLevel=\(coverLevel) panelLevel=\(panelLevel)")
                        lines.append("panelVisible=\(panel.isVisible) panelKey=\(panel.isKeyWindow) "
                                     + "nsappActive=\(NSApp.isActive)")
                        lines.append("keyWindow=\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil")")
                        for w in NSApp.windows {
                            lines.append("window class=\(String(describing: type(of: w))) "
                                         + "level=\(w.level.rawValue) visible=\(w.isVisible) key=\(w.isKeyWindow)")
                        }
                        lines.append("aboveMain=\(panelLevel > mainLevel) aboveCover=\(panelLevel > coverLevel) "
                                     + "isPicking=\(FilePanels.isPicking)")
                        // Activating the app for the picker must NOT claim a
                        // Dock tile again (LSUIElement / .accessory shape).
                        lines.append("activationPolicy=\(NSRunningApplication.current.activationPolicy.rawValue) "
                                     + "wantsDockTile=\(self.wantsDockTile)")
                        lines.append("resignSuppressed=\(FilePanels.isPicking)")
                        lines.append("DONE")
                        try? (lines.joined(separator: "\n") + "\n")
                            .write(toFile: "/tmp/launchos-wallpaper-picker.log", atomically: true, encoding: .utf8)
                        panel.cancel(nil)
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    private func writeProbeWallpaper(to url: URL) {
        let image = NSImage(size: NSSize(width: 120, height: 80))
        image.lockFocus()
        NSColor(red: 0.95, green: 0.2, blue: 0.1, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 120, height: 80)).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    /// Diagnostic entry point: `LaunchOS --layout-tools-probe` exercises the
    /// compact / backup / restore tools and the inset geometry against an
    /// isolated state directory. Writes /tmp/launchos-debug.log and quits.
    private func startLayoutToolsProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--layout-tools-probe") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.model.runLayoutToolsProbe()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
        }
    }

    /// Diagnostic: `LaunchOS --brand-probe` proves the visible product name is
    /// Gridora in Info.plist and in every AppBrand-derived string, while the
    /// executable / identifier / bundle / cloud snapshot keep their persisted
    /// "LaunchOS" names. Off by default; writes /tmp/launchos-brand.log.
    private func startBrandProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--brand-probe") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            _ = BrandProbe.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
        }
    }

    /// Diagnostic: `LaunchOS --appearance-probe` checks the appearance layer
    /// with pure functions: the inline glass preview follows every Settings
    /// value, the backdrop stays low-chroma (the detector is verified against
    /// the old violet colours first), ranges match the captions, and Reduce
    /// Motion still collapses the shared durations.
    private func startAppearanceProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--appearance-probe") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            _ = AppearanceProbe.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
        }
    }

    /// Diagnostic: `Gridora --search-hotkey-probe` proves the configurable
    /// search chord, the letter-to-search switch, the legacy state upgrade and
    /// short-token relevance all read their single sources of truth.
    private func startSearchHotKeyProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--search-hotkey-probe") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            _ = SearchHotKeyProbe.run(model: self.model)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
        }
    }

    /// Diagnostic: `Gridora --launcher-hotkey-probe` drives the REAL Carbon
    /// registration path (`applyLauncherHotKey`) and the real key monitor
    /// decision (`LauncherModel.handleKey`), plus state.json upgrade, conflict
    /// resolution and the recorder validator.
    private func startLauncherHotKeyProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--launcher-hotkey-probe") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            _ = LauncherHotKeyProbe.run(model: self.model, delegate: self)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
        }
    }

    /// Diagnostic: `Gridora --residency-probe` proves the global start key
    /// survives a hide. It really hides the window, keeps the process alive,
    /// fires the registered hotkey handler and asserts the window returns;
    /// it also asserts the macOS 15 fade leaves the content layer at identity.
    private func startResidencyProbeIfNeeded() {
        ResidencyProbe.startIfNeeded(delegate: self, model: model)
    }

    /// Diagnostic entry point: `LaunchOS --edge-inset-probe` proves the four
    /// independent insets drive drawing + hit testing and that old single-
    /// value state files upgrade without changing the rendered grid.
    private func startEdgeInsetProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--edge-inset-probe") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.model.runEdgeInsetProbe()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
        }
    }

    /// Diagnostic entry point: `LaunchOS --sync-folder-probe` verifies the
    /// folder-panel CONFIGURATION: armed through FilePanels.prepare(), above
    /// both launcher windows, isPicking set, directory-only.
    ///
    /// IMPORTANT: this probe deliberately uses begin() on a prepared panel
    /// and therefore does NOT cover the real Settings action. On 2026-11-09
    /// it reported PASS while `chooseFolder()` still used runModal(), which
    /// reset the panel to level 8 and buried it — the button looked dead.
    /// The real action is driven by --picker-path-probe; never accept a PASS
    /// here as proof that the button works.
    private func startSyncFolderProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--sync-folder-probe") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            var lines: [String] = []
            let mainLevel = self.window?.level.rawValue ?? -1
            let coverLevel = self.menuCover?.level.rawValue ?? -1

            // Exactly the panel LayoutSync.chooseFolder() prepares.
            let panel = LayoutSync.shared.probeMakeFolderPanel()
            let panelLevel = panel.level.rawValue
            let pickingAfterPrepare = FilePanels.isPicking
            lines.append("mainLevel=\(mainLevel) coverLevel=\(coverLevel) panelLevel=\(panelLevel)")
            lines.append("isPickingAfterPrepare=\(pickingAfterPrepare)")
            lines.append("canChooseDirectories=\(panel.canChooseDirectories) "
                         + "canChooseFiles=\(panel.canChooseFiles) "
                         + "canCreateDirectories=\(panel.canCreateDirectories)")

            panel.begin { _ in FilePanels.release() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                lines.append("panelVisible=\(panel.isVisible) panelKey=\(panel.isKeyWindow) "
                             + "nsappActive=\(NSApp.isActive)")
                lines.append("keyWindow=\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil")")
                lines.append("aboveMain=\(panelLevel > mainLevel) aboveCover=\(panelLevel > coverLevel) "
                             + "isPickingDuring=\(FilePanels.isPicking)")
                lines.append("activationPolicy=\(NSRunningApplication.current.activationPolicy.rawValue) "
                             + "resignSuppressed=\(FilePanels.isPicking)")
                let levelOK = panelLevel > mainLevel && panelLevel > coverLevel
                let folderOnly = panel.canChooseDirectories && !panel.canChooseFiles
                let guardOK = pickingAfterPrepare && FilePanels.isPicking
                lines.append("ASSERT levelAboveBoth=\(levelOK) folderOnly=\(folderOnly) "
                             + "prepareAndGuard=\(guardOK)")
                lines.append(levelOK && folderOnly && guardOK ? "PASS" : "FAIL")
                lines.append("DONE")
                try? (lines.joined(separator: "\n") + "\n")
                    .write(toFile: "/tmp/launchos-sync-folder.log", atomically: true, encoding: .utf8)
                panel.cancel(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            }
        }
    }

    /// Diagnostic entry point: `LaunchOS --picker-path-probe` drives the REAL
    /// Settings → 同步 action and samples the window state while it runs.
    ///
    /// --sync-folder-probe built a look-alike panel and called begin(), so it
    /// could report PASS while chooseFolder() blocked the main thread with
    /// runModal(): on an .accessory app the pending activate() then never
    /// completes, the panel never becomes key, and the button looks dead.
    /// The timer is registered in .common so it also fires inside AppKit's
    /// modal-panel run-loop mode while runModal() owns the main thread.
    private func startPickerPathProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--picker-path-probe") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            let mainLevel = self.window?.level.rawValue ?? -1
            let coverLevel = self.menuCover?.level.rawValue ?? -1
            var lines: [String] = []
            let out = "/tmp/launchos-picker-path.log"
            let write = {
                try? (lines.joined(separator: "\n") + "\n")
                    .write(toFile: out, atomically: true, encoding: .utf8)
            }
            var didReturn = false
            var duringLevel = -1
            var duringKey = false
            var duringVisible = false
            var duringPicking = false
            var duringBlocking = false
            var duringActive = false
            var duringDone = false
            var afterDone = false
            var finished = false

            func finish() {
                guard duringDone, afterDone, !finished else { return }
                finished = true
                // Give cancel() time to deliver the begin() completion; the
                // isPicking guard must be released or quitOnHide is dead.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    let released = !FilePanels.isPicking
                    let levelOK = duringLevel > mainLevel && duringLevel > coverLevel
                    // Headless sessions cannot activate an .accessory app:
                    // the already-working wallpaper picker measures the same
                    // panelKey=false / nsappActive=false here. Only require
                    // key status when the app is genuinely active.
                    let keyOK = duringKey || !duringActive
                    let ok = levelOK && duringVisible && duringPicking
                             && !duringBlocking && keyOK && released
                    lines.append("mainLevel=\(mainLevel) coverLevel=\(coverLevel)")
                    lines.append("ASSERT duringLevel=\(duringLevel) aboveBoth=\(levelOK) "
                                 + "panelVisible=\(duringVisible) panelKey=\(duringKey) "
                                 + "guiSessionActive=\(duringActive) keyOK=\(keyOK) "
                                 + "guardArmed=\(duringPicking) guardReleased=\(released) "
                                 + "actionNonBlocking=\(!duringBlocking)")
                    lines.append(ok ? "PASS" : "FAIL")
                    lines.append("DONE")
                    write()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
                }
            }

            func sample(_ tag: String) {
                let panels = NSApp.windows.filter { $0 is NSOpenPanel }
                let p = panels.first
                let level = p?.level.rawValue ?? -1
                let visible = p?.isVisible ?? false
                let key = p?.isKeyWindow ?? false
                lines.append("\(tag) chooseFolderReturned=\(didReturn) "
                             + "openPanels=\(panels.count) panelLevel=\(level) "
                             + "panelVisible=\(visible) panelKey=\(key) "
                             + "nsappActive=\(NSApp.isActive) "
                             + "keyWindow=\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil") "
                             + "isPicking=\(FilePanels.isPicking)")
                if tag == "DURING" {
                    duringLevel = level
                    duringVisible = visible
                    duringKey = key
                    duringPicking = FilePanels.isPicking
                    duringActive = NSApp.isActive
                    duringBlocking = !didReturn
                    duringDone = true
                } else {
                    afterDone = true
                }
                finish()
            }

            let t = Timer(timeInterval: 0.7, repeats: false) { _ in
                sample("DURING")
                (NSApp.windows.first { $0 is NSOpenPanel } as? NSOpenPanel)?.cancel(nil)
                write()   // keep partial evidence if runModal never returns
            }
            RunLoop.main.add(t, forMode: .common)

            LayoutSync.shared.chooseFolder()   // the exact action behind the button
            didReturn = true
            sample("AFTER")
        }
    }

    /// Diagnostic entry point: `LaunchOS --icloud-sync-probe` exercises the
    /// coordinated iCloud Drive write, the evicted-file download guard and the
    /// cross-Mac pull against an isolated LAUNCHOS_SYNC_DIR, then quits.
    private func startICloudSyncProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--icloud-sync-probe") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.model.runICloudSyncProbe()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { NSApp.terminate(nil) }
        }
    }

    /// Diagnostic entry point: `LaunchOS --merge-probe` synthesises icon drags
    /// in both directions and a folder drop-out at a known grid cell. Writes
    /// /tmp/launchos-debug.log and quits. Always pair it with an isolated
    /// LAUNCHOS_STATE_DIR.
    private func startMergeProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--merge-probe") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.model.runMergeProbe()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
        }
    }

    /// Diagnostic entry point: `LaunchOS --folder-interaction-probe` drives
    /// the real model entry points behind the four open-folder / drag
    /// behaviours: artwork-only click hit testing, in-folder reorder,
    /// wheel + key page turns, and the grid's live make-way preview. Writes
    /// /tmp/launchos-folder-interaction.log and quits. Always pair it with an
    /// isolated LAUNCHOS_STATE_DIR.
    private func startFolderInteractionProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--folder-interaction-probe") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.model.runFolderInteractionProbe(
                consume: Self.folderShouldConsumeScroll)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
        }
    }

    /// Diagnostic entry point: `LaunchOS --layout-probe` exercises the sync
    /// snapshot and the folder drag-out path against an isolated state dir,
    /// writes /tmp/launchos-layout-probe.log and quits.
    private func startLayoutProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--layout-probe") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.model.runLayoutProbe()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { NSApp.terminate(nil) }
        }
    }

    /// Diagnostic entry point: `LaunchOS --wheel-probe` feeds synthetic wheel
    /// notches through the real interaction engine and writes the resulting
    /// page destinations to /tmp/launchos-debug.log, then quits.
    private func startWheelProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--wheel-probe") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.model.runWheelProbe()
            // The probe now exercises spaced wheel flicks and three separate
            // display-link settles; give every asynchronous assertion time.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { NSApp.terminate(nil) }
        }
    }

    /// Diagnostic entry point: `LaunchOS --fps-probe` measures frame times
    /// for ~6 s and terminates by itself. See Support/FrameProbe.swift.
    private func startProbeIfNeeded() {
        guard ProbeConfig.enabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, let view = self.window?.contentView else { return }
            let dragMode = ProbeConfig.dragFPS
            let folderMode = ProbeConfig.folderFPS
            if folderMode {
                // Open a real multi-page folder before the paging window
                // starts at 2.0 s. Without one the drive below would page the
                // (hidden) main grid and quietly measure the wrong thing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self else { return }
                    let multi = self.model.allFolders.first {
                        self.model.folderPageCount(for: $0.id) > 1
                    }
                    if let multi {
                        self.model.openFolderID = multi.id
                        self.model.setFolderPage(0)
                        self.log("fps folder=\(multi.bundleIDs.count) apps id=\(multi.id)")
                    } else {
                        self.log("fps folder=NONE (need a folder with 10+ apps)")
                    }
                }
            }
            FrameProbe.shared.start(view: view, drive: { [weak self] in
                guard let self, !dragMode else { return }
                if folderMode {
                    guard self.model.openFolderID != nil else { return }
                    self.model.turnFolderPage(self.model.folderPage == 0 ? 1 : -1)
                    return
                }
                let count = max(1, self.model.pageCount)
                self.model.goToPage((self.model.currentPage + 1) % count)
            }, onFrame: dragMode ? { [weak self] frame in
                self?.model.driveProbeDragFrame(frame)
            } : nil)
        }
    }

    private func runDemoIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains(where: { $0.hasPrefix("--demo") || $0 == "--self-test" }) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            self.log("demo args=\(args.dropFirst())")
            if args.contains("--demo-search") { self.model.openSearch("ca") }
            if args.contains(where: { $0.hasPrefix("--demo-settings") }) {
                if let arg = args.first(where: { $0.hasPrefix("--demo-settings=") }) {
                    let key = String(arg.dropFirst("--demo-settings=".count))
                    self.model.settingsPage = SettingsPage.allCases
                        .first(where: { $0.rawValue == key }) ?? .general
                    self.log("demo settings page=\(self.model.settingsPage.rawValue)")
                }
                self.model.showSettings()
            }
            if args.contains("--demo-hidden") {
                self.model.debugHideSome()
                self.model.showHidden()
                self.log("demo hidden open=\(self.model.hiddenOpen) count=\(self.model.hiddenTiles.count)")
            }
            if args.contains("--demo-folder") { self.model.debugMakeFolder() }
            if args.contains("--demo-vertical") {
                self.model.settings.vertical = true
                self.model.layoutSettingsChanged()
            }
            if args.contains("--demo-drag") { self.model.debugDragDemo() }
            if args.contains("--self-test") { self.model.runSelfTest() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        log("willTerminate")
        // A normal quit (menu / Cmd-Q) must not lose the last debounced edit.
        // Diagnostic runs never touch the user's state file.
        if !diagnosticMode { model.flush() }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
    }

    private var activatedAt = Date.distantPast
    /// Start of the "ignore reopen" window after a cold launch.
    private var launchedAt = Date()
    /// Guards against a stale hide completion ordering out a window that has
    /// just been shown again by a hotkey press during the fade.
    private var hideGeneration = 0

    private var menuCover: NSWindow?

    func applicationDidBecomeActive(_ notification: Notification) {
        activatedAt = Date()
        log("didBecomeActive visible=\(window?.isVisible ?? false) key=\(window?.isKeyWindow ?? false)")
        // iCloud may have delivered a newer layout while the launcher was
        // hidden; check immediately rather than waiting for the 12 s poll.
        LayoutSync.shared.checkRemote()
    }

    func applicationDidResignActive(_ notification: Notification) {
        log("didResignActive visible=\(window?.isVisible ?? false)")
        // A modeless NSOpenPanel is served by an XPC process; clicking away
        // to find a picture is normal and must not hide the launcher (and
        // with quitOnHide, terminate the process) mid-selection.
        guard !FilePanels.isPicking else {
            log("resign ignored (file picker open)")
            return
        }
        // Ignore the focus flap that happens in the first moments after a
        // programmatic launch (`open`, Dock-less start). Launchpad should stay
        // put in that window, but still disappear when the user really leaves.
        // An .accessory app may never post didBecomeActive. Without the
        // distantPast check, that sentinel would pass the 0.6 s test and the
        // delayed check below could close a visible launcher on a focus flap.
        guard activatedAt != .distantPast,
              Date().timeIntervalSince(activatedAt) > 0.6 else {
            log("resign ignored (startup race / never activated)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, let window = self.window,
                  window.isVisible, !NSApp.isActive else { return }
            self.hideLauncher()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A cold launch from the Dock can be followed by a reopen; that one
        // must not immediately toggle the launcher back off.
        guard Date().timeIntervalSince(launchedAt) > 0.8 else { return true }
        guard let window else { return true }
        // Clicking the Dock icon behaves like Launchpad: open when closed,
        // close when already open.
        if model.isShown && window.isVisible {
            hideLauncher()
        } else {
            showLauncher()
        }
        return true
    }

    // MARK: - Hot keys

    /// Single entry point for the system-wide launcher shortcut. Called on
    /// cold start (after state.json loads) and from Settings on every change.
    /// Exposed (not private) so `--launcher-hotkey-probe` drives the real path
    /// instead of a look-alike helper.
    func applyLauncherHotKey() {
        let chord = model.settings.launcherHotKey
        // The shipped default keeps the two legacy spare chords; any custom
        // chord replaces all three so "my shortcut" means exactly one key.
        let combos = chord.hasSameCombo(as: .defaultLauncher)
            ? [chord] + KeyChord.legacyAlternates
            : [chord]
        GlobalHotKey.shared.register(combos)
        launcherMenuItem?.title = "显示启动台  \(chord.label)"
        log("hotkey configured=\(chord.label) combos=\(combos.map(\.label).joined(separator: ","))"
            + " available=\(GlobalHotKey.shared.hasAnyHotKey) status=\(GlobalHotKey.shared.lastStatus)")
        if GlobalHotKey.shared.lastRegistrationFailed, model.settingsOpen {
            model.toast = "「\(chord.label)」可能被系统占用，请换一个按键"
        }
    }

    /// Read by `--launcher-hotkey-probe` to prove the status-bar menu follows
    /// the configured chord instead of a stale hard-coded string.
    var launcherMenuItemTitle: String { launcherMenuItem?.title ?? "" }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        appMenu.addItem(withTitle: "显示启动台", action: #selector(showLauncherAction), keyEquivalent: "")
            .target = self
        appMenu.addItem(withTitle: "设置…", action: #selector(openSettingsAction), keyEquivalent: ",")
            .target = self
        appMenu.addItem(withTitle: "已隐藏的 App", action: #selector(openHiddenAction), keyEquivalent: "")
            .target = self
        appMenu.addItem(withTitle: "重新扫描应用", action: #selector(rescanAction), keyEquivalent: "r")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: AppBrand.quitTitle, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "显示")
        viewMenuItem.submenu = viewMenu
        // No keyEquivalent: the combo is configurable in Settings and owned by
        // the key monitor. A hard-coded ⌘F here would be consumed by AppKit's
        // menu system before the monitor ever saw a custom chord.
        viewMenu.addItem(withTitle: "搜索 App", action: #selector(searchAction), keyEquivalent: "")
            .target = self
        viewMenu.addItem(withTitle: "已隐藏的 App", action: #selector(openHiddenAction), keyEquivalent: "H")
            .target = self

        NSApp.mainMenu = mainMenu
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: AppBrand.statusItemDescription)
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        let show = menu.addItem(withTitle: "显示启动台  \(model.settings.launcherHotKey.label)",
                                action: #selector(showLauncherAction), keyEquivalent: "")
        show.target = self
        launcherMenuItem = show
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(openSettingsAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "已隐藏的 App", action: #selector(openHiddenAction), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: AppBrand.quitTitle, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    // MARK: - Window

    private func buildWindow() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let window = LauncherWindow(contentRect: frame,
                                    styleMask: [.borderless],
                                    backing: .buffered,
                                    defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // Launchpad sits *below* the Dock (kCGDockWindowLevel = 20) so the
        // Dock stays visible and clickable, and hides the menu bar via its
        // presentation options while open.
        window.level = NSWindow.Level(rawValue: 19)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.animationBehavior = .none

        let hosting = NSHostingView(rootView: LauncherView().environmentObject(model))
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        window.contentView = hosting

        // The paging engine needs a display-bound vsync source. Asking for the
        // 60–120 Hz range lets ProMotion panels drive scrolling at 120 Hz.
        model.scrollEngine.attach(to: hosting)

        self.window = window
    }

    private func currentScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
    }

    private func positionWindow() {
        guard let window, let screen = currentScreen() else { return }
        window.setFrame(screen.frame, display: true)
        window.contentView?.frame = NSRect(origin: .zero, size: screen.frame.size)
    }

    /// Height of the Dock strip on the launcher's screen, 0 when the Dock is
    /// set to auto-hide, plus the current menu-bar height. The grid leaves
    /// room for the Dock at the bottom, and the click-through cover replacement
    /// for the menu bar is fed the exact strip height.
    private func updateMetrics() {
        guard let screen = currentScreen() else { return }
        let autoHideDock = UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false
        let dock = autoHideDock ? 0 : screen.visibleFrame.minY - screen.frame.minY
        let menu = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        model.dockHeight = max(0, dock)
        model.menuBarHeight = max(0, min(menu, 64))
        log("metrics dock=\(model.dockHeight) menu=\(model.menuBarHeight)")
    }

    private func positionMenuCover() {
        guard let menuCover, let screen = currentScreen() else { return }
        menuCover.setFrame(screen.frame, display: true)
        menuCover.contentView?.frame = NSRect(origin: .zero, size: screen.frame.size)
    }

    /// A click-through strip above the launcher that hides the real menu bar
    /// (Launchpad does the same) without killing activation of anything.
    private func buildMenuCover() {
        let window = NSWindow(contentRect: .zero,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.orderOut(nil)
        window.alphaValue = 0

        let hosting = NSHostingView(rootView: MenuBarCover().environmentObject(model))
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting

        menuCover = window
    }

    /// Pure decision used by the key monitor and by `--search-realuse-probe`.
    /// A stale shared field editor is not proof of active editing: it must
    /// belong to a panel that is currently open.
    static func isTextEditing(_ firstResponderIsTextView: Bool,
                               searchOpen: Bool,
                               panelOpen: Bool) -> Bool {
        firstResponderIsTextView && (searchOpen || panelOpen)
    }

    // MARK: - Monitors

    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // While Settings records a shortcut, the recorder must be the only
            // consumer. Returning the event (not nil) passes it on to its
            // monitor; a launcher action must not fire mid-recording.
            if HotKeyRecorder.isRecording { return event }
            guard let self,
                  let window = self.window,
                  window.isVisible,
                  window.isKeyWindow else { return event }
            // The window's shared field editor can outlive a closed search
            // overlay. If it stays first responder, the monitor believes the
            // user is still typing and hands every letter to that dead editor
            // instead of reopening search: `query` changes off-screen while
            // the results stay frozen on the first search. Only trust a text
            // responder while a panel that actually owns a text field is open.
            let panelOpen = self.model.settingsOpen || self.model.hiddenOpen
                || self.model.openFolderID != nil || self.model.renamingFolderID != nil
            let editing = Self.isTextEditing(window.firstResponder is NSTextView,
                                             searchOpen: self.model.searchOpen,
                                             panelOpen: panelOpen)
            return self.model.handleKey(event, textEditing: editing) ? nil : event
        }

        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.shouldConsumeScrollEvent() else { return event }
            self.model.handleScroll(event)
            return nil
        }

        // An open folder has no NSScrollView of its own. The pager monitor
        // above hands the wheel back to AppKit in every panel state, so before
        // this second monitor the event simply disappeared on multi-page
        // folders. Settings / hidden / search keep their own ScrollViews and
        // take priority via `otherPanelOpen`.
        folderScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  Self.folderShouldConsumeScroll(
                      windowVisible: self.window?.isVisible ?? false,
                      windowKey: self.window?.isKeyWindow ?? false,
                      folderOpen: self.model.openFolderID != nil,
                      otherPanelOpen: self.model.settingsOpen
                          || self.model.hiddenOpen || self.model.searchOpen) else { return event }
            self.model.handleFolderScroll(event)
            return nil
        }
    }

    /// Pure decision behind the folder wheel monitor. A visible, key launcher
    /// window with a folder on top and no other panel claims the event; every
    /// other state lets AppKit deliver it to whatever SwiftUI ScrollView owns
    /// the screen. Kept separate from `pagerShouldConsumeScroll` so the
    /// settings-scroll regression keeps asserting its original semantics.
    static func folderShouldConsumeScroll(windowVisible: Bool,
                                          windowKey: Bool,
                                          folderOpen: Bool,
                                          otherPanelOpen: Bool) -> Bool {
        windowVisible && windowKey && folderOpen && !otherPanelOpen
    }

    /// Pure decision behind the scroll monitor: only the visible, key launcher
    /// window with no panel on top may consume a wheel event. Panels carry
    /// their own NSScrollView (the layout settings page outgrows the 508 pt
    /// panel), so swallowing the event there made it impossible to scroll.
    /// Returning the original event lets AppKit deliver it to that scroll
    /// view; `handleScroll` already ignores every panel state.
    static func pagerShouldConsumeScroll(windowVisible: Bool,
                                         windowKey: Bool,
                                         panelOpen: Bool) -> Bool {
        windowVisible && windowKey && !panelOpen
    }

    private func shouldConsumeScrollEvent() -> Bool {
        Self.pagerShouldConsumeScroll(windowVisible: window?.isVisible ?? false,
                                      windowKey: window?.isKeyWindow ?? false,
                                      panelOpen: model.scrollBelongsToPanel)
    }

    // MARK: - Show / hide

    func showLauncher() {
        guard let window else { return }
        // Re-read the system preference each time the launcher appears. This
        // covers a user toggling "Reduce motion" in System Settings while the
        // app is running, without relying on a private notification name.
        Motion.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        log("showLauncher screen=\(currentScreen()?.frame ?? .zero)")
        hideGeneration += 1
        model.scrollEngine.cancel()
        positionWindow()
        positionMenuCover()
        model.refreshWallpaper()
        updateMetrics()
        model.isShown = false
        WindowReveal.reset(window)
        window.alphaValue = 0
        menuCover?.alphaValue = 0
        menuCover?.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        log("show-ready since-launch=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - launchStart))s")

        // Diagnostic only: samples display-link intervals during this very
        // show. Default-off, and the second (warm) show in the same process is
        // driven by the probe itself so cold-start cost can be separated from
        // the animation cost.
        OpenAnimationProbe.shared.attach(view: window.contentView) { [weak self] action in
            switch action {
            case .hide: self?.hideLauncher()
            case .show: self?.showLauncher()
            }
        }

        switch OpenAnimationConfig.mode {
        case .fade:
            // macOS 15 Launchpad: the grid is already at its final position
            // and size behind a fully transparent window. Only window alpha
            // animates, on the compositor, so no tile is re-evaluated on any
            // intermediate frame (the old SwiftUI path measured 44–166 ms
            // long frames / 8–10% jank on a cold launch).
            model.isShown = true
            WindowReveal.fadeShow(window: window, cover: menuCover,
                                  duration: Motion.fadeInDuration)
        case .scale:
            // One-variable A/B control: the old centre-out reveal on the
            // content layer. SwiftUI still changes exactly once.
            model.isShown = true
            WindowReveal.show(window: window, cover: menuCover,
                              duration: Motion.openDuration,
                              startScale: Motion.openStartScale)
        case .legacy:
            // Reproducible control for --open-probe and a one-variable
            // rollback switch; deliberately keeps the old SwiftUI transaction.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.windowDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
                menuCover?.animator().alphaValue = 1
            }
            withAnimation(.easeOut(duration: Motion.windowDuration)) {
                model.isShown = true
            }
        case .none:
            // Identical setup work with no animation at all (A/B control).
            model.isShown = true
            WindowReveal.instantShow(window: window, cover: menuCover)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self else { return }
            log("post-show visible=\(self.window?.isVisible ?? false) level=\(self.window?.level.rawValue ?? -1)")
        }
    }

    func hideLauncher() {
        guard let window else { return }
        log("hideLauncher")
        hideGeneration += 1
        model.scrollEngine.cancel()
        let generation = hideGeneration
        switch OpenAnimationConfig.mode {
        case .fade:
            // Symmetric cross-fade out. The grid keeps its geometry, so
            // `isShown = false` causes no visible jump while alpha falls.
            model.closeTransient()
            model.isShown = false
            WindowReveal.fadeHide(window: window, cover: menuCover,
                                  duration: Motion.fadeOutDuration) { [weak self] in
                Task { @MainActor in
                    self?.finishHide(generation)
                }
            }
        case .scale:
            // A/B control: symmetric collapse back into the centre. Still no
            // SwiftUI transaction: overlays close in one update and the layer
            // animates.
            model.closeTransient()
            model.isShown = false
            WindowReveal.hide(window: window, cover: menuCover,
                              duration: Motion.openDuration,
                              endScale: Motion.openStartScale) { [weak self] in
                // NSAnimationContext may deliver its completion off the main
                // actor; hop back before touching windows or model state.
                Task { @MainActor in
                    self?.finishHide(generation)
                }
            }
        case .legacy:
            withAnimation(.easeOut(duration: Motion.windowDuration)) {
                model.closeTransient()
                model.isShown = false
            }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Motion.windowDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 0
                menuCover?.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    self?.finishHide(generation)
                }
            })
        case .none:
            model.closeTransient()
            model.isShown = false
            WindowReveal.instantHide(window: window, cover: menuCover)
            finishHide(generation)
        }
    }

    @MainActor
    private func finishHide(_ generation: Int) {
        guard hideGeneration == generation, !model.isShown else { return }
        window?.orderOut(nil)
        menuCover?.orderOut(nil)
        // Undo the collapsed layer transform so a later reveal always starts
        // from a clean identity (WindowReveal.show also resets, this is the
        // belt-and-braces path for a hide interrupted by a reopen).
        WindowReveal.reset(window)
        if let window { window.alphaValue = 1 }

        guard !FilePanels.isPicking else {
            log("finishHide deferred (file picker still open)")
            return
        }
        // `persist()` is debounced by 0.35 s and the cloud push by 1 s; write
        // synchronously now or the last layout / launch-count edit is lost —
        // also in resident mode, where the process is no longer guaranteed to
        // stay alive until a user quits it cleanly.
        model.flush()
        guard shouldExitOnHide else {
            // The whole point of staying resident: the Carbon start key stays
            // registered, so F3 / ⌃⌥Space can bring this hidden window back.
            log("resident: window hidden, process and hotkey kept alive")
            return
        }
        // `activate(_:)` opens the picked app 0.06 s after hiding starts.
        // With Reduce Motion the fade lasts ~1 ms, so give that pending launch
        // time to leave the process before we tear it down.
        log("quit-on-hide armed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self,
                  self.hideGeneration == generation,
                  !self.model.isShown,
                  !(self.window?.isVisible ?? false) else {
                self?.log("quit-on-hide cancelled (reshown)")
                return
            }
            self.log("quit-on-hide terminate")
            NSApp.terminate(nil)
        }
    }

    func toggleLauncher() {
        guard let window else { return }
        if window.isVisible && window.isKeyWindow {
            hideLauncher()
        } else {
            showLauncher()
        }
    }

    // MARK: - Actions

    @objc private func showLauncherAction() { showLauncher() }
    @objc private func openSettingsAction() { showLauncher(); model.showSettings() }
    @objc private func openHiddenAction() { showLauncher(); model.showHidden() }
    @objc private func rescanAction() { model.scanApps() }
    @objc private func searchAction() { showLauncher(); model.openSearch() }
}
