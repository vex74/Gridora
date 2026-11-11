import AppKit
import SwiftUI

struct Press {
    var page: Int
    var tileID: String?
    var localStart: CGPoint
    var containerStart: CGPoint
    var startScroll: CGFloat
    var paging = false
    var moved = false
}

@MainActor
final class LauncherModel: ObservableObject {

    static let shared = LauncherModel()

    /// High-frequency paging state, deliberately outside the model's
    /// objectWillChange stream. See ScrollState in Models.swift.
    let scroll = ScrollState()
    let pageState = PageState()
    /// Drag state is split so a 120 Hz pointer stream only invalidates the
    /// floating tile layer, not every icon in every page.
    let dragInfo = DragSemanticState()
    let dragMotion = DragMotionState()
    /// A drag out of an open folder is also split by frequency. The folder
    /// panel sees only "which app / outside the panel", the floating icon sees
    /// only the pointer position.
    let folderDragInfo = FolderDragInfo()
    let folderDragMotion = FolderDragMotion()
    /// Window-space frame of the pager, written through a PreferenceKey. Used
    /// on drop to turn a folder-drag location into a grid cell. Not published.
    var pagerFrameInWindow: CGRect = .zero
    /// Display-synced scroll / settle engine (attached to the hosting view).
    lazy var scrollEngine = ScrollEngine(owner: self)

    // Data
    @Published var appsByID: [String: AppInfo] = [:]
    @Published var pages: [[Tile]] = []
    @Published var hiddenTiles: [Tile] = []
    @Published var settings = Settings()
    @Published var usage: [String: Usage] = [:]
    @Published var manualHidden: Set<String> = []
    @Published var pinned: Set<String> = []

    // Live UI state
    @Published var areaSize: CGSize = .zero
    @Published var isShown = false
    @Published var isLoading = true
    @Published var dockHeight: CGFloat = 0
    @Published var menuBarHeight: CGFloat = 0
    @Published var wallpaper: NSImage?
    /// Source / failure reason shown in the appearance settings pane. A wallpaper
    /// that cannot be read must be visible to the user, not silently reset.
    @Published var wallpaperStatus: String = "未检测"

    /// Quantised backdrop inputs shared by the main window and the click-through
    /// menu-bar cover. Quantising stops a slider drag from rebuilding the
    /// full-screen blur every frame; both surfaces must use the *identical*
    /// values or the top strip shows a visible seam against the wallpaper.
    var quantizedBackdropBlur: CGFloat { (settings.backgroundBlur / 5).rounded() * 5 }
    var quantizedBackdropDim: Double { (settings.backgroundDim / 0.02).rounded() * 0.02 }

    /// v1.6.2: the ICON-FREE backdrop the MAIN window paints under its fog.
    /// Exactly the inputs `MenuBarCover` passes to `BackgroundView`, so both
    /// windows' Liquid Glass samples are pixel-identical. No new setting.
    var fogPlate: FogPlate {
        FogPlate(useWallpaper: settings.useWallpaper,
                 wallpaper: wallpaper,
                 blur: quantizedBackdropBlur,
                 dim: quantizedBackdropDim)
    }

    @Published var press: Press?
    /// Interaction-engine state only. Intentionally NOT @Published: the UI
    /// reads the split `dragInfo` / `dragMotion` objects instead, so moving
    /// the pointer no longer invalidates the whole view tree.
    var drag: DragState?
    // Layout snapshot taken when a drag starts. Merge detection runs against
    // it: the tile you aim at must not vanish from under the cursor while the
    // rest of the grid reflows around the dragged icon.
    private var dragBase: [Tile] = []
    private var dragBasePage = -1
    private var lastProbeLocation: CGPoint = .zero
    /// Make-way preview throttling. Publishing an insertion slot re-renders a
    /// whole rasterised page (measured: 42% jank at 120 Hz under a synthetic
    /// drag that crossed a cell every frame, versus 4.5% with the preview
    /// off). A real pointer crosses a ~100 pt cell every 50–100 frames, but
    /// cap the republish rate anyway so a fast flick cannot flood the raster.
    private var lastReflowPublish: TimeInterval = 0
    private var pendingReflow: Int?
    private var reflowWork: DispatchWorkItem?
    @Published var selection: Int?
    @Published var flashID: String?

    @Published var searchOpen = false
    /// Projection of the live search field's text, used only to compute
    /// `searchResults`. The AppKit field is the single source of truth: every
    /// external write must go through `setSearchText` so the visible text and
    /// this value can never diverge. A Chinese IME can commit "广告" straight
    /// into the field editor without a `controlTextDidChange`, and writing the
    /// stale `query` back into the field on the next SwiftUI recompute used to
    /// roll the Chinese text back to the previous ASCII query.
    @Published var query = ""
    weak var searchField: NSTextField?
    @Published var searchSelection = 0
    /// Bumped on every `openSearch`. `PanelLayer` uses it as the SearchOverlay
    /// identity so a close/reopen rebuilds the view: @FocusState otherwise
    /// keeps its old `true`, the async `focused = true` in onAppear becomes a
    /// no-op, and the field editor never becomes first responder again — the
    /// symptom is "only the first search shows results, later keystrokes are
    /// dropped". Deliberately not @Published: openSearch already publishes.
    var searchGeneration = 0

    @Published var settingsOpen = false
    /// Selected category inside the light settings panel; survives reopening.
    @Published var settingsPage: SettingsPage = .general
    @Published var hiddenOpen = false
    /// The open folder owns the wheel, the arrow keys and the page-turn chords
    /// while it is on screen. `folderPage` is the single source of truth for
    /// which 3 × 3 page is shown: the panel, the wheel, the keyboard, the page
    /// dots and the diagnostics all read and write this one value.
    @Published var openFolderID: String? {
        didSet {
            guard oldValue != openFolderID else { return }
            folderPage = 0
            folderDragInfo.dropSlot = nil
            resetFolderWheel()
        }
    }
    @Published var folderPage = 0
    @Published var renamingFolderID: String?
    /// Pager-container point of the folder icon that opened the panel. Plain
    /// property (not @Published): FolderOverlay reads it once on appearance to
    /// grow the panel out of that tile, like macOS 15 Launchpad.
    var folderOpenOrigin: CGPoint?

    @Published var toast: String?

    var onHide: (() -> Void)?
    /// Fired by Settings whenever a shortcut changes. AppDelegate owns the
    /// Carbon re-registration; the model stays ignorant of AppKit/Carbon.
    var onHotKeysChanged: (() -> Void)?

    private var saveWork: DispatchWorkItem?
    private var edgeWork: DispatchWorkItem?
    private var snapWork: DispatchWorkItem?
    private var layoutWork: DispatchWorkItem?
    /// Discrete wheel flicks since the last page turn. We count *events*,
    /// not points: one physical flick is one NSEvent, while its delta can be
    /// anywhere from 3 lines to ~24 points depending on the mouse and the
    /// system scroll-speed preference. High-resolution wheels and some drivers
    /// split a single flick into several events a few ms apart; those are
    /// coalesced into one flick by `lastWheelEventTimestamp`.
    private var wheelNotches = 0
    private var wheelNotchDirection = 0
    private var lastWheelEventTimestamp: TimeInterval = 0
    /// Folder pages are discrete, so their wheel has its own coalescing state.
    /// Reusing the pager's counters would make one folder flick leave a stale
    /// notch that fires the instant the folder closes.
    private var folderWheelNotches = 0
    private var folderWheelDirection = 0
    private var folderWheelLastUptime: TimeInterval = 0
    private var folderGestureAccum: CGFloat = 0
    private var folderGestureConsumed = false
    private var didLoad = false
    private var wallpaperLoading = false
    /// A force-refresh requested while a decode is already in flight used to be
    /// dropped silently by the `wallpaperLoading` guard — the picked path was
    /// saved but the background never changed. Queue one retry instead.
    private var pendingWallpaperReload = false
    /// Path used for the currently cached wallpaper, so changing the custom
    /// image (or clearing it) forces a reload without re-decoding on every open.
    private var lastWallpaperPath: String?

    // MARK: - Geometry

    /// Facade over ScrollState: every reader/writer in the interaction engine
    /// keeps working, but a per-frame scroll change invalidates only the pager.
    /// The settled page is published on a separate low-frequency object.
    var scrollPos: CGFloat {
        get { scroll.position }
        set {
            scroll.position = newValue
            let extent = pageExtent
            guard extent > 1 else { return }
            let raw = Int((newValue / extent).rounded())
            let settled = min(max(raw, 0), pageCount - 1)
            if pageState.index != settled { pageState.index = settled }
        }
    }

    /// Actual point insets derived from the per-edge stored fractions. Based
    /// on the shorter page dimension so one slider value looks consistent
    /// regardless of the window's aspect ratio.
    var gridInsetsPoints: GridEdgeInsets {
        let base = min(areaSize.width, areaSize.height)
        let range = Settings.gridInsetRange
        func pt(_ v: Double) -> CGFloat {
            let safe = v.isFinite ? v : range.lowerBound
            return CGFloat(min(max(safe, range.lowerBound), range.upperBound)) * base
        }
        let e = settings.gridInsets
        return GridEdgeInsets(top: pt(e.top), left: pt(e.left),
                              bottom: pt(e.bottom), right: pt(e.right))
    }

    /// Legacy single-value helper (left edge) for diagnostics.
    var gridInsetPoints: CGFloat { gridInsetsPoints.left }

    var metrics: GridMetrics {
        GridMetrics(size: areaSize,
                    cols: max(3, settings.columns),
                    rows: max(2, settings.rows),
                    iconScale: settings.iconScale,
                    showsLabels: settings.showLabels,
                    insets: gridInsetsPoints)
    }

    var pageExtent: CGFloat {
        settings.vertical ? areaSize.height : areaSize.width
    }

    var pageCount: Int { max(1, pages.count) }

    var currentPage: Int {
        guard pageExtent > 1 else { return 0 }
        return min(max(Int((scrollPos / pageExtent).rounded()), 0), pageCount - 1)
    }

    func pageOrigin(_ index: Int) -> CGPoint {
        let offset = CGFloat(index) * pageExtent - scrollPos
        return settings.vertical ? CGPoint(x: 0, y: offset) : CGPoint(x: offset, y: 0)
    }

    func localPoint(_ container: CGPoint, page: Int) -> CGPoint {
        let origin = pageOrigin(page)
        return CGPoint(x: container.x - origin.x, y: container.y - origin.y)
    }

    func containerPoint(_ local: CGPoint, page: Int) -> CGPoint {
        let origin = pageOrigin(page)
        return CGPoint(x: local.x + origin.x, y: local.y + origin.y)
    }

    // MARK: - Loading

    func bootstrap() {
        guard !didLoad else { return }
        didLoad = true

        if let saved = StateStore.load() {
            settings = saved.settings
            usage = saved.usage
            manualHidden = Set(saved.manualHidden)
            pinned = Set(saved.pinned)
            hiddenTiles = saved.hidden
            pages = saved.pages
        }

        refreshWallpaper()
        scanApps()
    }

    /// Loads the desktop picture only when the user opted in — reading the file
    /// can trigger a TCC prompt, so it never happens on first launch, and it
    /// always runs off the main thread.
    ///
    /// macOS 15 returns a *directory* from `desktopImageURL(for:)` when the
    /// wallpaper is an image folder; the old code failed to decode it and reset
    /// `settings.useWallpaper` to false, which made the switch look broken.
    /// Now the Wallpaper Store is parsed as well, and a failed lookup never
    /// mutates the switch — `BackgroundView` simply falls back to the built-in
    /// procedural backdrop while `wallpaperStatus` explains why.
    func refreshWallpaper(force: Bool = false) {
        guard settings.useWallpaper else {
            wallpaper = nil
            wallpaperStatus = "已关闭"
            lastWallpaperPath = nil
            return
        }
        let path = settings.wallpaperPath
        if !force, wallpaper != nil, lastWallpaperPath == path { return }
        guard !wallpaperLoading else {
            pendingWallpaperReload = true
            return
        }
        wallpaperLoading = true
        wallpaperStatus = "正在读取壁纸…"

        let screen = NSScreen.main
        Task.detached(priority: .utility) {
            let result = WallpaperResolver.resolve(customPath: path, screen: screen)
            await MainActor.run {
                self.wallpaperLoading = false
                self.wallpaper = result.image
                self.wallpaperStatus = result.status
                self.lastWallpaperPath = path
                if self.pendingWallpaperReload {
                    self.pendingWallpaperReload = false
                    self.refreshWallpaper(force: true)
                }
            }
        }
    }

    /// Single entry point for a user-picked picture/folder. Lives on the model
    /// so the Settings button and the diagnostic probe exercise the identical
    /// settings -> resolver -> cache -> persist chain.
    func applyWallpaperPath(_ url: URL) {
        settings.wallpaperPath = url.path
        // Picking a picture is explicit intent to see it, even when the
        // master switch was off. (The Settings onChange may refresh once more;
        // the pending queue collapses that into one final decode.)
        settings.useWallpaper = true
        refreshWallpaper(force: true)
        persist()
    }

    func clearWallpaperPath() {
        settings.wallpaperPath = nil
        refreshWallpaper(force: true)
        persist()
    }

    func scanApps() {
        isLoading = true
        AppScanner.extraFolders = settings.extraFolders
        Task {
            let apps = await Task.detached(priority: .userInitiated) { AppScanner.scan() }.value
            self.applyScan(apps)
        }
    }

    private func applyScan(_ apps: [AppInfo]) {
        var map: [String: AppInfo] = [:]
        for app in apps { map[app.bundleID] = app }
        appsByID = map

        let now = Date()
        for app in apps where usage[app.bundleID] == nil {
            usage[app.bundleID] = Usage(firstSeen: now)
        }

        let hiddenIDs = Set(hiddenTiles.compactMap { $0.isFolder ? nil : $0.bundleID })
        var placed = Set<String>()
        var restoredPages: [[Tile]] = []

        for page in pages {
            var tiles: [Tile] = []
            for tile in page {
                if let folder = tile.folder {
                    var kept: [String] = []
                    for id in folder.bundleIDs where map[id] != nil && !placed.contains(id) && !hiddenIDs.contains(id) {
                        kept.append(id)
                        placed.insert(id)
                    }
                    if kept.count >= 2 {
                        var copy = folder
                        copy.bundleIDs = kept
                        tiles.append(.makeFolder(copy))
                    } else if let only = kept.first {
                        tiles.append(.app(only))
                    }
                } else if let id = tile.bundleID,
                          map[id] != nil,
                          !placed.contains(id),
                          !hiddenIDs.contains(id) {
                    tiles.append(.app(id))
                    placed.insert(id)
                }
            }
            restoredPages.append(tiles)
        }

        // drop hidden tiles that no longer exist
        hiddenTiles = hiddenTiles.filter { tile in
            if let folder = tile.folder {
                return folder.bundleIDs.contains { map[$0] != nil }
            }
            return tile.bundleID.map { map[$0] != nil } ?? false
        }

        // append newly discovered apps
        var leftovers = apps
            .filter { !placed.contains($0.bundleID) && !hiddenIDs.contains($0.bundleID) }
            .map { Tile.app($0.bundleID) }
        let capacity = max(1, metrics.capacity)
        if restoredPages.isEmpty { restoredPages = [[]] }
        while !leftovers.isEmpty {
            let room = capacity - (restoredPages.last?.count ?? 0)
            if room <= 0 {
                restoredPages.append([])
                continue
            }
            let take = Array(leftovers.prefix(room))
            leftovers.removeFirst(take.count)
            restoredPages[restoredPages.count - 1].append(contentsOf: take)
        }

        pages = reflowed(restoredPages)
        if pages.isEmpty { pages = [[]] }
        scrollPos = min(scrollPos, CGFloat(pageCount - 1) * pageExtent)
        isLoading = false
        applyAutoHide()
        persist()
    }

    private func reflowed(_ input: [[Tile]]) -> [[Tile]] {
        let flat = input.flatMap { $0 }
        let capacity = max(1, metrics.capacity)
        var output: [[Tile]] = []
        var index = 0
        while index < flat.count {
            let end = min(index + capacity, flat.count)
            output.append(Array(flat[index..<end]))
            index = end
        }
        return output.isEmpty ? [[]] : output
    }

    // MARK: - Persistence

    func persist() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let state = PersistedState(pages: self.pages,
                                       hidden: self.hiddenTiles,
                                       settings: self.settings,
                                       usage: self.usage,
                                       manualHidden: Array(self.manualHidden),
                                       pinned: Array(self.pinned))
            StateStore.save(state)
            LayoutSync.shared.localLayoutChanged()
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// Synchronous counterpart to `persist()`. The 0.35 s debounce (and the
    /// 1 s cloud push) can never fire if the process exits immediately after
    /// hiding, so the exit path must call this before terminating.
    func flush() {
        saveWork?.cancel()
        saveWork = nil
        let state = PersistedState(pages: pages,
                                   hidden: hiddenTiles,
                                   settings: settings,
                                   usage: usage,
                                   manualHidden: Array(manualHidden),
                                   pinned: Array(pinned))
        StateStore.save(state)
        LayoutSync.shared.pushNow()
    }

    /// Replace only the arrangement with a snapshot from another Mac. The
    /// normal app reconciliation then drops bundle IDs that do not exist here
    /// and appends newly installed apps; settings and usage stay local.
    func applySyncedLayout(_ layout: SyncedLayout) {
        pages = layout.pages
        hiddenTiles = layout.hidden
        manualHidden = Set(layout.manualHidden)
        pinned = Set(layout.pinned)
        openFolderID = nil
        selection = nil
        scanApps()
        clampScroll()
    }

    // MARK: - Pages

    func clampScroll() {
        guard pageExtent > 1 else { return }
        let maxPos = CGFloat(pageCount - 1) * pageExtent
        scrollPos = min(max(scrollPos, 0), maxPos)
    }

    func goToPage(_ page: Int, animated: Bool = true) {
        guard pageExtent > 1 else { return }
        cancelSnap()
        scrollEngine.cancel()
        let target = min(max(page, 0), pageCount - 1)
        if animated {
            scrollEngine.animate(to: CGFloat(target) * pageExtent)
        } else {
            scrollPos = CGFloat(target) * pageExtent
        }
        if let sel = selection, sel >= (pages[target].count) {
            selection = pages[target].isEmpty ? nil : pages[target].count - 1
        }
    }

    func goToPage(containing tileID: String) {
        for (index, page) in pages.enumerated() where page.contains(where: { $0.id == tileID }) {
            goToPage(index)
            return
        }
    }

    /// Sliders mutate `settings` on every frame. Reflowing every page and
    /// scheduling a save on each of those frames made the layout pane stutter.
    /// Coalesce them into a single commit shortly after dragging stops.
    func scheduleLayoutCommit() {
        layoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.layoutWork = nil
            self?.layoutSettingsChanged()
        }
        layoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func layoutSettingsChanged() {
        pages = reflowed(pages)
        if pages.isEmpty { pages = [[]] }
        clampScroll()
        applyAutoHide()
        persist()
    }

    /// Explicit "compact pages" action. `reflowed` flattens every page, drops
    /// empty pages and re-packs to the current grid capacity. The model
    /// already reflows after every edit, so this is idempotent for now; it
    /// becomes meaningful once free-form placement can leave empty slots.
    @discardableResult
    func compactPages() -> (before: Int, after: Int) {
        let before = pages.count
        pages = reflowed(pages)
        if pages.isEmpty { pages = [[]] }
        clampScroll()
        persist()
        return (before, pages.count)
    }

    // MARK: - Hiding

    var autoHiddenIDs: Set<String> {
        guard settings.autoHideUnused else { return [] }
        let cutoff = Date().addingTimeInterval(-Double(max(1, settings.autoHideDays)) * 86_400)
        var ids = Set<String>()
        for (id, record) in usage where appsByID[id] != nil {
            if manualHidden.contains(id) || pinned.contains(id) { continue }
            let last = record.lastLaunch ?? record.firstSeen
            if last < cutoff && record.launches <= 1 { ids.insert(id) }
        }
        return ids
    }

    func applyAutoHide() {
        let ids = autoHiddenIDs
        guard !ids.isEmpty else { return }
        var moved: [Tile] = []
        var newPages: [[Tile]] = []

        for page in pages {
            var newTiles: [Tile] = []
            for tile in page {
                if let id = tile.bundleID {
                    if ids.contains(id) { moved.append(tile) } else { newTiles.append(tile) }
                    continue
                }
                if var folder = tile.folder {
                    let removed = folder.bundleIDs.filter { ids.contains($0) }
                    folder.bundleIDs.removeAll { ids.contains($0) }
                    moved.append(contentsOf: removed.map { Tile.app($0) })
                    if folder.bundleIDs.count >= 2 {
                        newTiles.append(.makeFolder(folder))
                    } else if let only = folder.bundleIDs.first {
                        newTiles.append(.app(only))
                    }
                    continue
                }
            }
            newPages.append(newTiles)
        }

        if !moved.isEmpty {
            hiddenTiles.append(contentsOf: moved)
            pages = reflowed(newPages)
            if pages.isEmpty { pages = [[]] }
            clampScroll()
            persist()
        }
    }

    func hide(tileID: String) {
        guard let (pageIndex, tile) = locate(tileID) else { return }
        withAnimation(Motion.reorder) {
            pages[pageIndex].removeAll { $0.id == tileID }
            hiddenTiles.append(tile)
            if let id = tile.bundleID { manualHidden.insert(id) }
            pages = reflowed(pages)
            if pages.isEmpty { pages = [[]] }
        }
        clampScroll()
        persist()
    }

    func unhide(tileID: String) {
        guard let index = hiddenTiles.firstIndex(where: { $0.id == tileID }) else { return }
        let tile = hiddenTiles.remove(at: index)
        if let id = tile.bundleID {
            manualHidden.remove(id)
            pinned.insert(id)
        }
        withAnimation(Motion.reorder) {
            if pages.isEmpty { pages = [[]] }
            pages[pages.count - 1].append(tile)
            pages = reflowed(pages)
        }
        clampScroll()
        persist()
    }

    func restoreAllHidden() {
        guard !hiddenTiles.isEmpty else { return }
        var tiles = hiddenTiles
        hiddenTiles = []
        for tile in tiles {
            if let id = tile.bundleID, let app = appsByID[id] {
                manualHidden.remove(id)
                pinned.insert(app.bundleID)
            }
        }
        withAnimation(Motion.reorder) {
            if pages.isEmpty { pages = [[]] }
            pages[pages.count - 1].append(contentsOf: tiles)
            pages = reflowed(pages)
        }
        clampScroll()
        persist()
    }

    // MARK: - Lookup

    func locate(_ tileID: String) -> (Int, Tile)? {
        for (pageIndex, page) in pages.enumerated() {
            if let tile = page.first(where: { $0.id == tileID }) {
                return (pageIndex, tile)
            }
        }
        return nil
    }

    func index(of tileID: String, in page: Int) -> Int? {
        guard page >= 0, page < pages.count else { return nil }
        return pages[page].firstIndex(where: { $0.id == tileID })
    }

    func folder(_ id: String) -> Folder? {
        for page in pages {
            if let tile = page.first(where: { $0.id == id }), let folder = tile.folder {
                return folder
            }
        }
        return nil
    }

    // MARK: - Pointer / drag

    func pointerDown(at point: CGPoint) {
        guard !isLoading, pageExtent > 1 else { return }
        // A click or grab must stop an in-flight settle spring, otherwise the
        // engine and the gesture would both write scrollPos in the same frame.
        scrollEngine.cancel()
        let page = currentPage
        let tiles = pages.indices.contains(page) ? pages[page] : []
        let local = localPoint(point, page: page)
        let index = metrics.iconIndex(at: local, count: tiles.count)
        press = Press(page: page,
                      tileID: index.map { tiles[$0].id },
                      localStart: local,
                      containerStart: point,
                      startScroll: scrollPos)
        if let index { selection = index } else { selection = nil }
    }

    func pointerDragged(from start: CGPoint, to point: CGPoint) {
        if press == nil { pointerDown(at: start) }
        guard var current = press else { return }

        if !current.moved {
            let distance = hypot(point.x - current.containerStart.x, point.y - current.containerStart.y)
            if distance > 4 {
                current.moved = true
                scrollEngine.cancel()
                if current.tileID != nil {
                    beginDrag(current)
                } else {
                    current.paging = true
                }
                press = current
            }
        }

        if drag != nil {
            updateDrag(point)
            return
        }

        if current.paging {
            let delta = settings.vertical
                ? point.y - current.containerStart.y
                : point.x - current.containerStart.x
            scrollPos = rubbered(current.startScroll - delta)
        }
    }

    func pointerUp(at point: CGPoint) {
        defer {
            press = nil
            cancelEdgeFlip()
        }
        guard let current = press else {
            handleClick(at: point)
            return
        }

        if drag != nil {
            // The release point is authoritative: never let the 3pt probe
            // throttle leave a merge target from the previous pointer event.
            updateDrag(point, force: true)
            finishDrag()
            return
        }

        if current.paging {
            let delta = scrollPos - current.startScroll
            let threshold = pageExtent * 0.14
            if abs(delta) > threshold {
                goToPage(current.page + (delta > 0 ? 1 : -1))
            } else {
                snapScroll()
            }
            return
        }

        if !current.moved {
            handleClick(at: point)
        }
    }

    func handleClick(at point: CGPoint) {
        let page = currentPage
        let local = localPoint(point, page: page)
        let tiles = pages.indices.contains(page) ? pages[page] : []
        guard let idx = metrics.iconIndex(at: local, count: tiles.count) else {
            // Clicking empty space behaves like Launchpad's "click to dismiss".
            selection = nil
            onHide?()
            return
        }
        selection = idx
        activate(tiles[idx], origin: point)
    }

    /// Trace merge resolution while dragging; helps diagnose real-hand drags.
    private func beginDrag(_ current: Press) {
        guard let id = current.tileID, let idx = index(of: id, in: current.page) else {
            press?.paging = true
            return
        }
        let center = metrics.iconCenter(of: idx)
        let grab = CGSize(width: center.x - current.localStart.x,
                          height: center.y - current.localStart.y)
        drag = DragState(tileID: id,
                         page: current.page,
                         location: current.containerStart,
                         grab: grab,
                         active: true,
                         mergeTarget: nil,
                         mergeSlot: nil,
                         sourceIndex: idx,
                         insertionSlot: nil,
                         velocity: 0,
                         lastLocation: current.containerStart)
        dragBase = pages.indices.contains(current.page) ? pages[current.page] : []
        dragBasePage = current.page
        lastProbeLocation = current.containerStart
        cancelReflow()
        lastReflowPublish = 0
        dragMotion.value = DragMotion(location: current.containerStart,
                                      velocity: 0,
                                      grab: grab)
        selection = idx
        syncDragSemantics()
    }

    /// Rebuilds the low-frequency drag description only when it actually
    /// changed. Every tile observes `dragInfo`, so this must stay quiet while
    /// the pointer is merely moving.
    private func syncDragSemantics() {
        let next = DragSemantics(active: drag != nil,
                                 sourceID: drag?.tileID,
                                 targetID: drag?.mergeTarget,
                                 slot: drag?.mergeSlot,
                                 page: drag?.page,
                                 sourceIndex: drag?.sourceIndex,
                                 insertionSlot: drag?.insertionSlot)
        if dragInfo.value != next { dragInfo.value = next }
    }

    func updateDrag(_ point: CGPoint, force: Bool = false) {
        guard var current = drag else { return }

        let previousLocation = current.lastLocation
        // A real 120 Hz mouse moves 1–2 pt between events; even a hard flick
        // stays well under 36 pt. Anything above that is a synthetic stress
        // stream (or a teleport), and previewing a reflow for it would rebuild
        // a rasterised page every frame for no perceptual benefit.
        let frameDistance = hypot(point.x - previousLocation.x,
                                  point.y - previousLocation.y)
        let fastFlick = frameDistance > 36

        let delta = point.x - current.lastLocation.x
        current.velocity = current.velocity * 0.55 + delta * 0.45
        current.location = point
        current.lastLocation = point
        drag = current

        // The ONLY per-pointer-event publish in the drag path. Just the
        // floating tile layer re-evaluates; all grid icons stay cached.
        dragMotion.value = DragMotion(location: point,
                                      velocity: current.velocity,
                                      grab: current.grab)

        // Merge resolution scans the page and may trigger a reflow. At 120 Hz
        // a pointer often moves 1–2 pt between events; redoing that work for
        // each one is pure waste and makes folder merging feel sticky.
        let travelled = hypot(point.x - lastProbeLocation.x,
                              point.y - lastProbeLocation.y)
        guard force || travelled >= 3 || dragInfo.value.targetID != current.mergeTarget else {
            return
        }
        lastProbeLocation = point

        guard let pageIndex = pages.indices.contains(current.page) ? current.page : nil,
              let draggedIndex = index(of: current.tileID, in: pageIndex) else { return }

        let local = localPoint(point, page: pageIndex)
        let tiles = pages[pageIndex]

        // Follow the artwork, not the cursor: when a tile is grabbed near its
        // edge the two differ by up to half an icon, which made merging feel
        // impossible in real use.
        let iconLocal = CGPoint(x: local.x + current.grab.width,
                                y: local.y + current.grab.height)

        var targetIndex = draggedIndex
        let probe = metrics.contains(iconLocal)
            ? iconLocal
            : CGPoint(x: min(max(iconLocal.x, 1), areaSize.width - 1),
                      y: min(max(iconLocal.y, 1), areaSize.height - 1))
        targetIndex = min(metrics.index(at: probe), max(0, tiles.count - 1))

        // macOS 15: the merge target is whichever icon the dragged artwork is
        // sitting on, and that icon stays put while a merge is possible. The
        // old logic reflowed the grid on every cell crossing, so the target
        // slid away from under the pointer; combined with a tight circular
        // radius it felt like one icon had to be pressed precisely onto the
        // other's original cell.
        let k = probeCell(probe)
        let baseCenter = metrics.iconCenter(of: k)
        // Rectangular artwork hit area with padding. Symmetric in both
        // directions and forgiving near the corners of the icon.
        // Clamp to the cell: at high icon scales the artwork is large enough that an
        // unclamped box would reach into the neighbouring slot and merge the
        // wrong tile.
        let hitX = max(20, min(metrics.iconSize / 2 + 22, metrics.cellW / 2 - 2))
        let hitY = max(20, min(metrics.iconSize / 2 + 18, metrics.cellH / 2 - 2))
        let overArtwork = abs(iconLocal.x - baseCenter.x) <= hitX
            && abs(iconLocal.y - baseCenter.y) <= hitY

        var merge: String?
        var mergeSlot: Int?
        if dragBasePage == pageIndex, dragBase.indices.contains(k),
           dragBase[k].id != current.tileID,
           overArtwork,
           let candidate = candidateForMerge(baseIndex: k) {
            merge = candidate.id
            mergeSlot = k
        } else if overArtwork,
                  let nearest = tiles.enumerated()
                      .filter({ $0.offset != draggedIndex && ($0.element.bundleID != nil || $0.element.isFolder) })
                      .min(by: {
                          let a = metrics.iconCenter(of: $0.offset)
                          let b = metrics.iconCenter(of: $1.offset)
                          return hypot(iconLocal.x - a.x, iconLocal.y - a.y)
                              < hypot(iconLocal.x - b.x, iconLocal.y - b.y)
                      }),
                  nearest.element.id != current.tileID {
            // Second chance: a tile genuinely under the artwork in the
            // *current* arrangement (e.g. the page changed mid-drag).
            let c = metrics.iconCenter(of: nearest.offset)
            if abs(iconLocal.x - c.x) <= hitX, abs(iconLocal.y - c.y) <= hitY {
                merge = nearest.element.id
                mergeSlot = nearest.offset
            }
        }
        if drag?.mergeTarget != merge || drag?.mergeSlot != mergeSlot {
            if debugTraceEnabled {
                debugLog("drag probe=(\(Int(probe.x)),\(Int(probe.y))) k=\(k) slotHit=\(dragBase.indices.contains(k) ? (dragBase[k].bundleID ?? "FOLDER") : "-") dragged#=\(draggedIndex) tgt=\(targetIndex) overIcon=\(overArtwork) merge=\(merge ?? "-") grab=(\(Int(current.grab.width)),\(Int(current.grab.height)))")
            }
            drag?.mergeTarget = merge
            drag?.mergeSlot = mergeSlot
        }

        // macOS 15 has two distinct drag states. Over a merge target the grid
        // stays frozen, otherwise the target slides out from under the artwork
        // and merge hit-testing starts finding the dragged tile itself. Over a
        // gap the other icons make way live. The committed reorder on release
        // uses this very same target slot, so the preview and the result can
        // never disagree. `pages` is never written here.
        //
        // Publishing a slot rebuilds a rasterised page. Throttle it to 10 Hz;
        // a real pointer only crosses a cell every 50–100 frames, so this
        // costs nothing in normal use but protects against a fast flick.
        // `force` (the release point) always publishes the final slot, which
        // keeps the preview and `reorderDraggedTile` identical.
        // `force` is the release point: it must always name the final slot,
        // even if the last pointer hop was unusually large, because
        // `reorderDraggedTile` commits exactly that slot.
        let candidate: Int? = merge == nil && ProbeConfig.liveReflow ? targetIndex : nil
        if candidate == nil {
            // A merge target appeared: freeze immediately, never debounced.
            cancelReflow()
            if drag?.insertionSlot != nil { drag?.insertionSlot = nil }
        } else if force {
            cancelReflow()
            drag?.insertionSlot = candidate
            lastReflowPublish = ProcessInfo.processInfo.systemUptime
        } else if fastFlick {
            // Keep the current preview, but do not rebuild a rasterised page
            // for a pointer teleport. The release point above still wins.
            cancelReflow()
        } else if drag?.insertionSlot == candidate {
            cancelReflow()
        } else {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastReflowPublish >= 0.10 {
                drag?.insertionSlot = candidate
                lastReflowPublish = now
                cancelReflow()
            } else {
                pendingReflow = candidate
                scheduleReflow()
            }
        }

        // Edge paging
        let threshold: CGFloat = 30
        if !settings.vertical, local.x < threshold, current.page > 0 {
            scheduleEdgeFlip(direction: -1)
        } else if !settings.vertical, local.x > areaSize.width - threshold {
            scheduleEdgeFlip(direction: 1)
        } else if settings.vertical, local.y < threshold, current.page > 0 {
            scheduleEdgeFlip(direction: -1)
        } else if settings.vertical, local.y > areaSize.height - threshold {
            scheduleEdgeFlip(direction: 1)
        } else {
            cancelEdgeFlip()
        }

        syncDragSemantics()
    }

    /// Grid cell of a point, clamped into the layout. `GridMetrics.index(at:)`
    /// is the single source of truth: it subtracts the four per-edge insets
    /// before dividing by the cell size. Re-implementing the arithmetic here
    /// without those insets shifted every merge probe by a column/row on any
    /// layout with non-zero margins, which made folder creation impossible.
    private func probeCell(_ point: CGPoint) -> Int {
        metrics.index(at: point)
    }

    /// Merge candidate from the drag-start snapshot: the tile this cell held
    /// when the drag began, provided it is still a folder-able tile.
    private func candidateForMerge(baseIndex: Int) -> (id: String, center: CGPoint)? {
        guard dragBase.indices.contains(baseIndex) else { return nil }
        let tile = dragBase[baseIndex]
        guard tile.bundleID != nil || tile.isFolder else { return nil }
        return (tile.id, metrics.iconCenter(of: baseIndex))
    }

    private func cancelReflow() {
        reflowWork?.cancel()
        reflowWork = nil
        pendingReflow = nil
    }

    /// Coalesces a burst of cell crossings into one make-way republish. The
    /// pending value is read at fire time, so the final slot always wins even
    /// if the pointer kept moving during the throttle window.
    private func scheduleReflow() {
        guard reflowWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reflowWork = nil
            guard let pending = self.pendingReflow, self.drag != nil else { return }
            self.drag?.insertionSlot = pending
            self.lastReflowPublish = ProcessInfo.processInfo.systemUptime
            self.pendingReflow = nil
            self.syncDragSemantics()
        }
        reflowWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: work)
    }

    private func scheduleEdgeFlip(direction: Int) {
        guard edgeWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.edgeWork = nil
            self.flipPageForDrag(direction: direction)
        }
        edgeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.40, execute: work)
    }

    func cancelEdgeFlip() {
        edgeWork?.cancel()
        edgeWork = nil
    }

    private func flipPageForDrag(direction: Int) {
        guard let current = drag else { return }
        let targetPage = current.page + direction
        guard targetPage >= 0 else { return }
        if targetPage >= pages.count { pages.append([]) }
        guard let sourceIndex = index(of: current.tileID, in: current.page) else { return }
        let tile = pages[current.page].remove(at: sourceIndex)
        let insertIndex = direction > 0 ? pages[targetPage].count : 0
        pages[targetPage].insert(tile, at: insertIndex)
        drag?.page = targetPage
        // The dragged tile now occupies a different index on a different
        // page; the make-way preview must follow it or every tile would shift
        // against a stale source index.
        drag?.sourceIndex = insertIndex
        drag?.insertionSlot = nil
        cancelReflow()
        // Fresh snapshot: merge detection now follows the new page.
        dragBase = pages[targetPage]
        dragBasePage = targetPage
        scrollEngine.animate(to: CGFloat(targetPage) * pageExtent)
        syncDragSemantics()
    }

    private func finishDrag() {
        guard let current = drag else { return }
        cancelEdgeFlip()
        cancelReflow()
        if let target = current.mergeTarget {
            merge(current.tileID, into: target)
        } else {
            reorderDraggedTile(current)
        }
        drag = nil
        dragBase = []
        dragBasePage = -1
        dragMotion.value = DragMotion()
        syncDragSemantics()
        selection = index(of: current.tileID, in: current.page)
        persist()
    }

    /// The one and only grid reorder, applied when a drag ends without a
    /// merge. Reflowing during the drag used to slide the merge target out
    /// from under the pointer; with the grid frozen, the drag-start snapshot
    /// stays valid and merge hit-testing is symmetric in both directions.
    private func reorderDraggedTile(_ current: DragState) {
        let pageIndex = current.page
        guard pages.indices.contains(pageIndex),
              let draggedIndex = index(of: current.tileID, in: pageIndex) else { return }
        let local = localPoint(current.location, page: pageIndex)
        // Follow the artwork rather than the raw cursor: a grab near the edge
        // can differ from the pointer by up to half an icon.
        let iconLocal = CGPoint(x: local.x + current.grab.width,
                                y: local.y + current.grab.height)
        let probe = metrics.contains(iconLocal)
            ? iconLocal
            : CGPoint(x: min(max(iconLocal.x, 1), areaSize.width - 1),
                      y: min(max(iconLocal.y, 1), areaSize.height - 1))
        let targetIndex = min(metrics.index(at: probe), max(0, pages[pageIndex].count - 1))
        guard targetIndex != draggedIndex else { return }
        withAnimation(Motion.reorder) {
            var array = pages[pageIndex]
            let item = array.remove(at: draggedIndex)
            array.insert(item, at: min(targetIndex, array.count))
            pages[pageIndex] = array
        }
    }

    func merge(_ sourceID: String, into targetID: String) {
        guard let (sourcePage, sourceTile) = locate(sourceID),
              let (targetPage, _) = locate(targetID),
              sourcePage == targetPage,
              var array = pages[safe: sourcePage],
              let sourceIndex = array.firstIndex(where: { $0.id == sourceID }) else { return }

        // Dropping a whole folder is allowed: its apps move into the target.
        let dragged: [String]
        if let single = sourceTile.bundleID {
            dragged = [single]
        } else if let folder = sourceTile.folder {
            dragged = folder.bundleIDs
        } else {
            return
        }
        guard !dragged.isEmpty else { return }

        array.remove(at: sourceIndex)
        guard let targetIndex = array.firstIndex(where: { $0.id == targetID }) else {
            pages[sourcePage] = array
            return
        }

        if var folder = array[targetIndex].folder {
            for id in dragged where !folder.bundleIDs.contains(id) {
                folder.bundleIDs.append(id)
            }
            array[targetIndex] = .makeFolder(folder)
        } else if let targetApp = array[targetIndex].bundleID {
            var ids = [targetApp]
            for id in dragged where id != targetApp { ids.append(id) }
            array[targetIndex] = .makeFolder(Folder(name: "文件夹", bundleIDs: ids))
        }

        withAnimation(Motion.reorder) { pages[sourcePage] = array }
        // A merge onto a plain app replaces that tile with a brand-new folder
        // id. Flashing the old app id therefore highlighted nothing.
        let folderID = array[targetIndex].id
        flashID = folderID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if self?.flashID == folderID { self?.flashID = nil }
        }
    }

    func rubbered(_ value: CGFloat) -> CGFloat {
        let extent = pageExtent
        guard extent > 1 else { return 0 }
        let maxPos = CGFloat(pageCount - 1) * extent
        if value < 0 { return value * 0.38 }
        if value > maxPos { return maxPos + (value - maxPos) * 0.38 }
        return value
    }

    // MARK: - Launch

    func activate(_ tile: Tile, origin: CGPoint? = nil) {
        if let folder = tile.folder {
            folderOpenOrigin = origin
            openFolderID = folder.id
            searchOpen = false
            selection = nil
            return
        }
        guard let id = tile.bundleID, let app = appsByID[id] else { return }
        launch(app)
    }

    func launch(_ app: AppInfo) {
        debugLog("launch \(app.name) — hiding launcher")
        var record = usage[app.bundleID] ?? Usage(firstSeen: Date())
        record.launches += 1
        record.lastLaunch = Date()
        usage[app.bundleID] = record

        flashID = app.bundleID
        persist()

        let url = app.url
        onHide?()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error { NSLog("Gridora: could not open \(app.name): \(error)") }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            if self?.flashID == app.bundleID { self?.flashID = nil }
        }
    }

    // MARK: - Search

    static let searchColumns = 6

    var visibleApps: [AppInfo] {
        var seen = Set<String>()
        var result: [AppInfo] = []
        for page in pages {
            for tile in page {
                if let id = tile.bundleID, let app = appsByID[id], !seen.contains(id) {
                    seen.insert(id)
                    result.append(app)
                }
                if let folder = tile.folder {
                    for id in folder.bundleIDs where !seen.contains(id) {
                        if let app = appsByID[id] {
                            seen.insert(id)
                            result.append(app)
                        }
                    }
                }
            }
        }
        return result
    }

    /// Single source of truth for tokenising a query. Unicode whitespace
    /// includes the full-width space U+3000 an IME can insert; splitting only
    /// on " " / "\t" left "微信　助手" as one token that matched nothing.
    static func searchTokens(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    var searchResults: [AppInfo] {
        let tokens = Self.searchTokens(query)
        let apps = visibleApps
        if tokens.isEmpty {
            return apps.sorted { usageScore($0) > usageScore($1) }.prefix(24).map { $0 }
        }

        // Every token must match (AND). AppInfo owns the scoring so the index
        // stays in one place: localised name, raw/Finder aliases, compact
        // pinyin, syllable initials and bundle id.
        guard !tokens.isEmpty else { return [] }

        var scored: [(AppInfo, Int)] = []
        for app in apps {
            let score = app.searchScore(for: tokens)
            if score > 0 { scored.append((app, score)) }
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                let lu = usageScore(lhs.0), ru = usageScore(rhs.0)
                if lu != ru { return lu > ru }
                return lhs.0.name.localizedStandardCompare(rhs.0.name) == .orderedAscending
            }
            .map { $0.0 }
    }

    private func usageScore(_ app: AppInfo) -> Int {
        guard let record = usage[app.bundleID] else { return 0 }
        let recent = record.lastLaunch.map { Date().timeIntervalSince($0) < 86_400 * 14 } ?? false
        return record.launches * 10 + (recent ? 50 : 0)
    }

    /// Single write path for search text. The field owns the visible string;
    /// updating both here keeps `query` and the field in lockstep, including
    /// the first character injected when a letter opens search over the grid
    /// and the clear button.
    func setSearchText(_ text: String) {
        query = text
        searchField?.stringValue = text
        (searchField as? LaunchOSSearchTextField)?.moveCaretToEnd()
        if searchSelection != 0 { searchSelection = 0 }
    }

    /// Field -> model direction. Called by the field's delegate and by its
    /// 0.1 s sync timer (a fallback for IME commits that never deliver
    /// `controlTextDidChange`). Never writes back into the field, so a SwiftUI
    /// recompute cannot roll back text the user just composed.
    func adoptFieldText(_ text: String) {
        guard query != text else { return }
        query = text
        if searchSelection != 0 { searchSelection = 0 }
    }

    func openSearch(_ initial: String = "") {
        setSearchText(initial)
        searchGeneration += 1
        searchOpen = true
        settingsOpen = false
        hiddenOpen = false
        openFolderID = nil
        selection = nil
    }

    func closeSearch() {
        searchOpen = false
        setSearchText("")
        searchSelection = 0
        // Retire the old field immediately. Its opacity transition can keep
        // it alive for another frame, and its sync timer must not race the
        // field of the next search session.
        searchField = nil
    }

    func moveSearchSelection(_ step: Int) {
        let count = searchResults.count
        guard count > 0 else { searchSelection = 0; return }
        searchSelection = min(max(searchSelection + step, 0), count - 1)
    }

    func launchSearchSelection() {
        let results = searchResults
        guard !results.isEmpty else { return }
        let index = min(max(searchSelection, 0), results.count - 1)
        let app = results[index]
        closeSearch()
        launch(app)
    }

    // MARK: - Keyboard

    func handleKey(_ event: NSEvent, textEditing: Bool) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyCode = event.keyCode
        let characters = (event.charactersIgnoringModifiers ?? "").lowercased()

        if keyCode == 53 { // esc
            if renamingFolderID != nil {
                renamingFolderID = nil
                return true
            }
            if searchOpen { closeSearch(); return true }
            if openFolderID != nil { openFolderID = nil; return true }
            if settingsOpen { settingsOpen = false; return true }
            if hiddenOpen { hiddenOpen = false; return true }
            if textEditing { return false }
            onHide?()
            return true
        }

        // The launcher chord is claimed system-wide by Carbon. If the local
        // monitor still sees that same physical key, never also interpret it
        // as typing, grid navigation or "open selected app": a bare A used to
        // open search and a bare Space used to activate a tile at the exact
        // moment Carbon hid the launcher. Proven by --launcher-hotkey-probe
        // (D group) before this guard was added.
        if settings.launcherHotKey.matches(event) { return true }

        // An open folder owns every page turn. Before this branch the wheel
        // was dropped entirely, bare ←/→ were swallowed by the panel guard,
        // and ⌘←/⌘→/⌘1–9 still flipped the *pager hidden behind* the folder.
        if openFolderID != nil, !textEditing {
            let prev = settings.previousPageHotKey
            let next = settings.nextPageHotKey
            let backward = keyCode == 123 || keyCode == 116 || prev.matches(event)
                || (prev.hasSameCombo(as: .defaultPreviousPage)
                    && flags.contains(.command) && keyCode == 123)
            let forward = keyCode == 124 || keyCode == 121 || next.matches(event)
                || (next.hasSameCombo(as: .defaultNextPage)
                    && flags.contains(.command) && keyCode == 124)
            if backward || forward {
                turnFolderPage(backward ? -1 : 1)
                return true
            }
            // ⌘1–9 must not address the pager that is covered by the panel.
            if flags.contains(.command), Int(characters) != nil { return true }
        }

        // The menu item no longer carries a keyEquivalent, so AppKit cannot
        // swallow the chord before this monitor sees it. Settings is the only
        // source of truth; a recorded combo takes effect without a restart.
        if !searchOpen, !settingsOpen, !hiddenOpen, openFolderID == nil,
           settings.searchHotKey.matches(event) {
            openSearch()
            return true
        }

        if searchOpen {
            switch keyCode {
            case 36, 76:
                launchSearchSelection()
                return true
            case 125:
                moveSearchSelection(Self.searchColumns)
                return true
            case 126:
                moveSearchSelection(-Self.searchColumns)
                return true
            case 123:
                moveSearchSelection(-1)
                return true
            case 124:
                moveSearchSelection(1)
                return true
            default:
                break
            }
            if flags.contains(.command), characters == "f" { return true }
            // Focus-independent fallback. SwiftUI can hand first responder
            // back to the window while the results subtree recomputes; a
            // printable key is then delivered to the window and vanishes, so
            // the grid keeps showing the previous search. Append it here and
            // consume the event, so `query` (and therefore the results) always
            // tracks what was typed. When the field editor is live we still
            // return false and let AppKit do normal text editing / IME.
            if !textEditing,
               !flags.contains(.command), !flags.contains(.control), !flags.contains(.option),
               let ch = event.characters?.first, ch.isLetter || ch.isNumber {
                setSearchText(query + String(ch))
                return true
            }
            return false
        }

        // Page-turn chords are configurable in Settings ▸ 快捷键. Matching
        // them before the Command-key defaults keeps the shipped ⌘← / ⌘→
        // behaviour, while a custom chord fully replaces it. The extra
        // condition for the default chords preserves the old behaviour where
        // ⇧⌘← / ⇧⌘→ also turned a page.
        if !searchOpen {
            let prev = settings.previousPageHotKey
            let next = settings.nextPageHotKey
            if prev.matches(event)
                || (prev.hasSameCombo(as: .defaultPreviousPage)
                    && flags.contains(.command) && keyCode == 123) {
                goToPage(currentPage - 1)
                return true
            }
            if next.matches(event)
                || (next.hasSameCombo(as: .defaultNextPage)
                    && flags.contains(.command) && keyCode == 124) {
                goToPage(currentPage + 1)
                return true
            }
        }

        if flags.contains(.command) {
            if characters == "," {
                settingsOpen.toggle()
                if settingsOpen { hiddenOpen = false }
                return true
            }
            if characters == "f" { openSearch(); return true }
            if characters == "r" { scanApps(); return true }
            if characters == "h" {
                hiddenOpen.toggle()
                if hiddenOpen { settingsOpen = false }
                return true
            }
            if let number = Int(characters), number >= 1, number <= 9 {
                goToPage(number - 1)
                return true
            }
            return false
        }

        if textEditing { return false }
        if settingsOpen || hiddenOpen || openFolderID != nil { return false }

        switch keyCode {
        case 123:
            moveSelection(dx: -1)
            return true
        case 124:
            moveSelection(dx: 1)
            return true
        case 125:
            moveSelection(dy: 1)
            return true
        case 126:
            moveSelection(dy: -1)
            return true
        case 36, 76:
            return activateSelection()
        case 48:
            moveSelection(dx: flags.contains(.shift) ? -1 : 1)
            return true
        case 49:
            return activateSelection()
        case 116:
            goToPage(currentPage - 1)
            return true
        case 121:
            goToPage(currentPage + 1)
            return true
        case 115:
            goToPage(0)
            return true
        case 119:
            goToPage(pageCount - 1)
            return true
        default:
            break
        }

        // Off by default: injecting the first letter into a field that does
        // not exist yet is where IME commits and fast typists lost characters.
        if settings.letterOpensSearch,
           !flags.contains(.command), !flags.contains(.control), !flags.contains(.option),
           let first = characters.first, first.isLetter || first.isNumber {
            openSearch(String(first))
            return true
        }
        return false
    }

    func moveSelection(dx: Int = 0, dy: Int = 0) {
        guard pageExtent > 1 else { return }
        let page = currentPage
        guard pages.indices.contains(page), !pages[page].isEmpty else { return }
        let cols = max(3, settings.columns)
        let rows = max(2, settings.rows)

        guard var index = selection else {
            selection = 0
            return
        }
        index = min(max(index, 0), pages[page].count - 1)

        var column = index % cols + dx
        var row = index / cols + dy

        if column < 0 {
            if page > 0 {
                goToPage(page - 1)
                selection = pages[page - 1].isEmpty ? nil : pages[page - 1].count - 1
            }
            return
        }
        if column >= cols {
            if page < pageCount - 1 {
                goToPage(page + 1)
                selection = pages[page + 1].isEmpty ? nil : 0
            }
            return
        }

        row = min(max(row, 0), rows - 1)
        var next = row * cols + column
        if next >= pages[page].count { next = pages[page].count - 1 }
        selection = max(0, next)
    }

    @discardableResult
    func activateSelection() -> Bool {
        let page = currentPage
        guard pages.indices.contains(page), !pages[page].isEmpty else { return false }
        let index = min(max(selection ?? 0, 0), pages[page].count - 1)
        selection = index
        let origin = containerPoint(metrics.iconCenter(of: index), page: page)
        activate(pages[page][index], origin: origin)
        return true
    }

    // MARK: - Scroll

    /// Test hook for `--wheel-probe`: keeps each synthetic case independent of
    /// the flick count left over by the previous one. No effect in normal use.
    func resetWheelNotchCount() {
        wheelNotches = 0
        wheelNotchDirection = 0
        lastWheelEventTimestamp = 0
    }

    /// Test hook for `--folder-interaction-probe`: each wheel case starts from
    /// a clean slate. Also called whenever a folder opens or closes, so a
    /// burst left over from the pager cannot fire inside the panel.
    func resetFolderWheel() {
        folderWheelNotches = 0
        folderWheelDirection = 0
        folderWheelLastUptime = 0
        folderGestureAccum = 0
        folderGestureConsumed = false
    }

    /// Number of 3 × 3 pages in an open folder. `bundleIDs` is the stored
    /// source of truth, so the wheel, keyboard and page dots can never
    /// disagree with the panel's chunks.
    func folderPageCount(for folderID: String) -> Int {
        guard let (_, tile) = locate(folderID), let folder = tile.folder else { return 0 }
        let per = FolderGridMetrics.perPage
        return max(1, (folder.bundleIDs.count + per - 1) / per)
    }

    func setFolderPage(_ page: Int) {
        guard let id = openFolderID else { return }
        folderPage = min(max(page, 0), max(0, folderPageCount(for: id) - 1))
    }

    func turnFolderPage(_ delta: Int) {
        setFolderPage(folderPage + delta)
    }

    /// Wheel events over an open folder. AppDelegate's dedicated local
    /// monitor hands them here instead of dropping them: the panel has no
    /// NSScrollView, so the pager's "pass the event through" rule used to
    /// leave the wheel completely inert on a multi-page folder.
    ///
    /// Discrete wheels use the same physical-flick coalescing as the pager
    /// (`systemUptime`, never `event.timestamp`, which synthetic events carry
    /// as a constant). Precise/phased trackpad events are clamped to at most
    /// one page per gesture — the same ±1 settle rule the paging engine uses.
    func handleFolderScroll(_ event: NSEvent) {
        guard let id = openFolderID, folderPageCount(for: id) > 1 else { return }
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        let raw = abs(dx) > abs(dy) ? dx : dy
        guard abs(raw) > 0.01 else { return }

        var direction = raw > 0 ? -1 : 1
        if settings.reverseScroll { direction = -direction }

        let phased = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        let discrete = !event.hasPreciseScrollingDeltas || !phased
        let ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)

        if discrete {
            let now = ProcessInfo.processInfo.systemUptime
            let gap = now - folderWheelLastUptime
            folderWheelLastUptime = now
            let pace = PagingRules.pace(settings.scrollSpeed)
            let burstWindow = PagingRules.burstWindow(pace: pace)
            let sameFlick = gap >= 0 && gap < burstWindow
                && direction == folderWheelDirection
            if direction != folderWheelDirection {
                folderWheelNotches = 0
                folderWheelDirection = direction
            }
            if sameFlick { return }
            folderWheelNotches += 1
            guard folderWheelNotches >= max(1, settings.wheelLines) else { return }
            folderWheelNotches = 0
            turnFolderPage(direction)
            return
        }

        // One continuous gesture = at most one page turn. A new gesture may
        // turn one more, but a single swipe can never stack two pages. The
        // threshold is the pager's own rule (`PagingRules.flickThreshold`),
        // with the panel width standing in for the page extent, so a swipe
        // that turns a page on the grid turns exactly one folder page too.
        if ended {
            folderGestureConsumed = false
            folderGestureAccum = 0
        }
        guard !folderGestureConsumed else { return }
        folderGestureAccum += abs(raw)
        let threshold = PagingRules.flickThreshold(extent: folderPanelWidth,
                                                   pace: PagingRules.pace(settings.scrollSpeed))
        guard folderGestureAccum >= threshold else { return }
        folderGestureAccum = 0
        folderGestureConsumed = true
        turnFolderPage(direction)
    }

    /// Width of the open folder panel, in points. Single source of truth: the
    /// panel view sizes itself with this value and the wheel above uses it as
    /// the page extent for `PagingRules.flickThreshold`, so drawing and input
    /// can never disagree about how wide a folder page is.
    var folderPanelWidth: CGFloat {
        min(760, max(560, areaSize.width * 0.42))
    }

    /// While a panel owns the screen the wheel belongs to that panel's own
    /// SwiftUI ScrollView, not to the pager. The app-level scroll monitor must
    /// hand the event back to AppKit in this state: returning nil starves the
    /// scroll view, and the layout page (taller than the fixed 508 pt panel)
    /// becomes impossible to scroll. Paging is suspended here anyway, so
    /// passing the event through costs no launcher behaviour.
    var scrollBelongsToPanel: Bool {
        settingsOpen || hiddenOpen || searchOpen || openFolderID != nil
    }

    func handleScroll(_ event: NSEvent) {
        guard !scrollBelongsToPanel else { return }
        guard pageExtent > 1 else { return }

        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        let raw = settings.vertical ? dy : (abs(dx) > 0.01 ? dx : dy)
        guard abs(raw) > 0.01 else { return }

        // Trackpad gestures always carry a phase. Discrete wheel notches do
        // not — including USB mice whose driver reports pixel-precise deltas
        // without a phase. Only phased events take the continuous path.
        let phased = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        let discrete = !event.hasPreciseScrollingDeltas || !phased
        WheelDiagnostics.log("event precise=\(event.hasPreciseScrollingDeltas)"
            + " phase=\(event.phase.rawValue) momentum=\(event.momentumPhase.rawValue)"
            + " dx=\(dx) dy=\(dy) discrete=\(discrete)"
            + " wheelLines=\(settings.wheelLines) pos=\(scrollPos) page=\(currentPage)")

        if discrete {
            handleWheelNotch(raw)
            return
        }

        var delta = raw
        if settings.reverseScroll { delta = -delta }
        // No direct write to scrollPos: the display link applies the sum of
        // all events received this frame, once, at the display's own cadence.
        scrollEngine.enqueue(-delta * CGFloat(settings.scrollSpeed),
                             phase: event.phase,
                             momentumPhase: event.momentumPhase)
    }

    /// Legacy wheel: count physical flicks, not points and not raw events.
    /// The previous implementation accumulated `scrollingDeltaY` against a
    /// fixed `wheelLines * 8` point threshold — a real notch is 3–24 points,
    /// so one notch was only half a turn and every page needed two flicks.
    /// Counting raw NSEvents fixed that, but high-resolution wheels deliver
    /// one physical flick as a burst of 2–4 events a few ms apart, which at
    /// `wheelLines = 1` turned two pages for a single flick. Coalesce a burst
    /// into one flick; a slower "scrolling speed" widens the coalescing window
    /// so the slider also softens discrete-wheel paging.
    private func handleWheelNotch(_ raw: CGFloat) {
        var direction = raw > 0 ? -1 : 1
        if settings.reverseScroll { direction = -direction }

        // System uptime, not `event.timestamp`: synthetic / driver-forwarded
        // scroll events can carry a constant or zero timestamp, which would
        // make every flick look simultaneous. This clock is monotonic and
        // works identically for real mouse events and the wheel probe.
        let now = ProcessInfo.processInfo.systemUptime
        let gap = now - lastWheelEventTimestamp
        lastWheelEventTimestamp = now
        let pace = CGFloat(min(max(settings.scrollSpeed, 0.4), 2.0))
        // 90 ms at the default; slower settings widen it so the slider also
        // softens discrete-wheel paging, faster settings narrow it. Capped at
        // 140 ms: two deliberate flicks can be ~160 ms apart, and swallowing
        // those would bring back the "it takes two flicks" regression.
        let burstWindow = TimeInterval(min(max(0.09 / pace, 0.05), 0.14))
        let sameFlick = gap >= 0 && gap < burstWindow
            && direction == wheelNotchDirection

        // Reversing direction must respond immediately instead of first
        // cancelling out notches accumulated in the other direction.
        let reversed = direction != wheelNotchDirection
        if reversed {
            wheelNotches = 0
            wheelNotchDirection = direction
        }
        WheelDiagnostics.log(String(format: "flick gap=%.4f window=%.3f same=%d reversed=%d",
                                    gap, burstWindow, sameFlick ? 1 : 0, reversed ? 1 : 0))
        if sameFlick {
            WheelDiagnostics.log("notch merged into current flick")
            return
        }
        wheelNotches += 1
        let required = max(1, settings.wheelLines)
        guard wheelNotches >= required else {
            WheelDiagnostics.log("notch \(wheelNotches)/\(required) — waiting")
            return
        }
        wheelNotches = 0

        // A flip may still be in flight. Count from its destination, not from
        // the rounded on-screen position: the latter re-targets the page the
        // previous notch already asked for and swallows the new notch.
        let base: Int
        if let destination = scrollEngine.destination {
            base = min(max(Int((destination / pageExtent).rounded()), 0), pageCount - 1)
        } else {
            base = currentPage
        }
        let target = min(max(base + direction, 0), pageCount - 1)
        WheelDiagnostics.log("notch -> page \(base) \(direction > 0 ? "+" : "-") 1 = \(target)")
        goToPage(target)
    }

    private func scheduleSnap(delay: TimeInterval = 0.16) {
        cancelSnap()
        let work = DispatchWorkItem { [weak self] in
            self?.snapWork = nil
            self?.snapScroll()
        }
        snapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelSnap() {
        snapWork?.cancel()
        snapWork = nil
    }

    func snapScroll() {
        guard pageExtent > 1 else { return }
        let raw = (scrollPos / pageExtent).rounded()
        let page = min(max(raw, 0), CGFloat(pageCount - 1))
        scrollEngine.animate(to: page * pageExtent)
    }

    // MARK: - Folder editing

    /// Every folder on every page, in grid order. Drives the "移动到文件夹"
    /// context menus; `Folder` is already Identifiable.
    var allFolders: [Folder] {
        pages.flatMap { $0 }.compactMap { $0.folder }
    }

    /// Move an app into an existing folder via the context menu. Unlike a drag
    /// merge, the destination is chosen from a list, so the source may live on
    /// a different page or inside another folder. A source folder that drops
    /// to one member dissolves back onto the grid, macOS 15 style.
    @discardableResult
    func moveAppIntoFolder(appID: String, folderID: String) -> Bool {
        guard let (_, destination) = locate(folderID),
              let target = destination.folder,
              !target.bundleIDs.contains(appID) else { return false }

        var result = pages
        var removed = false

        // 1. A standalone grid tile wins.
        gridLoop: for p in result.indices {
            if let idx = result[p].firstIndex(where: { $0.bundleID == appID }) {
                result[p].remove(at: idx)
                removed = true
                break gridLoop
            }
        }

        // 2. Otherwise the app lives inside another folder.
        if !removed {
            folderLoop: for p in result.indices {
                for t in result[p].indices {
                    guard var f = result[p][t].folder,
                          f.bundleIDs.contains(appID) else { continue }
                    f.bundleIDs.removeAll { $0 == appID }
                    if f.bundleIDs.count >= 2 {
                        result[p][t] = .makeFolder(f)
                    } else {
                        let survivors = f.bundleIDs.map { Tile.app($0) }
                        result[p].remove(at: t)
                        result[p].insert(contentsOf: survivors,
                                         at: min(t, result[p].count))
                    }
                    removed = true
                    break folderLoop
                }
            }
        }
        guard removed else { return false }

        // 3. Re-find the destination by id: removing or dissolving the source
        //    may have shifted every index on that page.
        guard let dp = result.firstIndex(where: { page in
                  page.contains { $0.id == folderID } }),
              let di = result[dp].firstIndex(where: { $0.id == folderID }),
              var destinationFolder = result[dp][di].folder else { return false }
        destinationFolder.bundleIDs.append(appID)
        result[dp][di] = .makeFolder(destinationFolder)

        withAnimation(Motion.reorder) { pages = result }
        flashID = folderID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if self?.flashID == folderID { self?.flashID = nil }
        }
        // Reveal the destination so the move has visible feedback.
        folderOpenOrigin = nil
        openFolderID = folderID
        persist()
        return true
    }

    /// Inserts a tile at the requested slot **on the requested page**. When
    /// that page is full, its last tile cascades into the following page (and
    /// so on), so every icon after the drop slot shifts by one — exactly like
    /// Launchpad. The old version skipped ahead to the first page with room,
    /// which made a drop on a full page land on another page at its tail and
    /// left the visible grid completely unchanged.
    ///
    /// Deliberately does NOT call `reflowed()`: that flattens every page and
    /// throws away the drop position the user just chose. The whole cascade is
    /// computed into a local and published once, so the grid is invalidated a
    /// single time.
    private func insertTile(_ tile: Tile, page: Int, slot: Int) {
        guard !pages.isEmpty else { pages = [[tile]]; return }
        let capacity = max(1, metrics.capacity)
        var result = pages
        var incoming = tile
        var target = min(max(page, 0), result.count - 1)
        var at = min(max(slot, 0), capacity - 1)

        while true {
            var array = result[target]
            let index = min(at, array.count)
            var spill: Tile?
            if array.count >= capacity { spill = array.removeLast() }
            array.insert(incoming, at: min(index, array.count))
            result[target] = array
            guard let spill else { break }
            incoming = spill
            target += 1
            at = 0
            if target >= result.count { result.append([]) }
        }
        pages = result
    }

    // MARK: - Dragging an app out of an open folder

    func beginFolderDrag(appID: String, folderID: String, at point: CGPoint) {
        folderDragInfo.appID = appID
        folderDragInfo.folderID = folderID
        folderDragInfo.outsidePanel = false
        folderDragInfo.dropSlot = nil
        folderDragMotion.position = point
    }

    /// Number of apps shown on the folder page currently on screen. The last
    /// page is usually short, and a drop must clamp to the icons actually
    /// present there rather than to a full 3 × 3 page.
    func folderVisibleCount(for folderID: String) -> Int {
        guard let (_, tile) = locate(folderID), let folder = tile.folder else { return 0 }
        let per = FolderGridMetrics.perPage
        let page = min(max(folderPage, 0), max(0, folderPageCount(for: folderID) - 1))
        return min(per, max(0, folder.bundleIDs.count - page * per))
    }

    func updateFolderDrag(to point: CGPoint,
                          panelFrame: CGRect,
                          gridFrame: CGRect? = nil,
                          grid: FolderGridMetrics? = nil) {
        folderDragMotion.position = point
        let outside = !panelFrame.insetBy(dx: -14, dy: -14).contains(point)
        if folderDragInfo.outsidePanel != outside { folderDragInfo.outsidePanel = outside }

        // Live make-way preview inside the panel. Only the cell index is
        // published, and only when it changes — the 120 Hz pointer stream
        // still touches nothing but the floating icon.
        var slot: Int?
        if !outside, let gridFrame, let grid, let id = openFolderID,
           gridFrame.insetBy(dx: -8, dy: -8).contains(point) {
            let local = CGPoint(x: point.x - gridFrame.minX,
                                y: point.y - gridFrame.minY)
            slot = grid.slot(at: local, count: folderVisibleCount(for: id))
        }
        if folderDragInfo.dropSlot != slot { folderDragInfo.dropSlot = slot }
    }

    /// Returns true only when the app actually left the panel and was placed
    /// back on the grid. A release *inside* the panel reorders the folder's
    /// members and leaves the folder open. `gridFrame` / `grid` are optional
    /// so the older layout/merge probes keep driving the exact same entry
    /// point with their original two arguments.
    @discardableResult
    func endFolderDrag(at point: CGPoint,
                       panelFrame: CGRect,
                       gridFrame: CGRect? = nil,
                       grid: FolderGridMetrics? = nil) -> Bool {
        defer {
            folderDragInfo.appID = nil
            folderDragInfo.folderID = nil
            folderDragInfo.outsidePanel = false
            folderDragInfo.dropSlot = nil
            folderDragMotion.position = .zero
        }
        guard let appID = folderDragInfo.appID,
              let folderID = folderDragInfo.folderID else { return false }

        if panelFrame.insetBy(dx: -14, dy: -14).contains(point) {
            if let gridFrame, let grid,
               gridFrame.insetBy(dx: -8, dy: -8).contains(point) {
                let local = CGPoint(x: point.x - gridFrame.minX,
                                    y: point.y - gridFrame.minY)
                let slot = grid.slot(at: local,
                                     count: folderVisibleCount(for: folderID))
                moveFolderApp(folderID: folderID, appID: appID, toSlot: slot)
            }
            return false
        }

        let container = CGPoint(x: point.x - pagerFrameInWindow.minX,
                                y: point.y - pagerFrameInWindow.minY)
        moveAppOutOfFolder(appID: appID, folderID: folderID, to: container)
        openFolderID = nil
        return true
    }

    /// Reorder a folder's own members. `slot` is relative to the folder page
    /// currently shown, so turning the folder page with the wheel or keys
    /// during a drag drops the app onto that page. `Folder.bundleIDs` is the
    /// stored source of truth — there is no second display order to drift.
    func moveFolderApp(folderID: String, appID: String, toSlot slot: Int) {
        guard let (pageIndex, tile) = locate(folderID),
              var folder = tile.folder,
              let from = folder.bundleIDs.firstIndex(of: appID),
              let tileIndex = pages[pageIndex].firstIndex(where: { $0.id == folderID }) else { return }
        let per = FolderGridMetrics.perPage
        let page = min(max(folderPage, 0), max(0, folderPageCount(for: folderID) - 1))
        let target = min(max(page * per + slot, 0), folder.bundleIDs.count - 1)
        guard target != from else { return }
        withAnimation(Motion.reorder) {
            var ids = folder.bundleIDs
            let moved = ids.remove(at: from)
            ids.insert(moved, at: target)
            folder.bundleIDs = ids
            pages[pageIndex][tileIndex] = .makeFolder(folder)
        }
        persist()
    }

    private func moveAppOutOfFolder(appID: String, folderID: String, to container: CGPoint) {
        guard let (folderPage, tile) = locate(folderID),
              var folder = tile.folder,
              folder.bundleIDs.contains(appID),
              pageExtent > 1 else { return }

        let page = currentPage
        let local = localPoint(container, page: page)
        let slot = metrics.index(at: local)

        withAnimation(Motion.reorder) {
            let remaining = folder.bundleIDs.filter { $0 != appID }
            if let idx = pages[folderPage].firstIndex(where: { $0.id == folderID }) {
                if remaining.count >= 2 {
                    folder.bundleIDs = remaining
                    pages[folderPage][idx] = .makeFolder(folder)
                } else {
                    // A folder with one survivor is not a folder: the survivor
                    // takes its slot, just like macOS Launchpad.
                    let replacements = remaining.map { Tile.app($0) }
                    pages[folderPage].remove(at: idx)
                    pages[folderPage].insert(contentsOf: replacements,
                                             at: min(idx, pages[folderPage].count))
                }
            }
            insertTile(.app(appID), page: page, slot: slot)
        }
        clampScroll()
        persist()
    }

    func renameFolder(id: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        for pageIndex in pages.indices {
            for tileIndex in pages[pageIndex].indices where pages[pageIndex][tileIndex].id == id {
                if var folder = pages[pageIndex][tileIndex].folder {
                    folder.name = trimmed
                    pages[pageIndex][tileIndex] = .makeFolder(folder)
                }
            }
        }
        persist()
    }

    func dissolveFolder(id: String) {
        guard let (pageIndex, tile) = locate(id), let folder = tile.folder else { return }
        withAnimation(Motion.reorder) {
            var array = pages[pageIndex]
            guard let index = array.firstIndex(where: { $0.id == id }) else { return }
            array.remove(at: index)
            let apps = folder.bundleIDs.filter { appsByID[$0] != nil }.map { Tile.app($0) }
            array.insert(contentsOf: apps, at: index)
            pages[pageIndex] = array
            pages = reflowed(pages)
        }
        persist()
    }

    func removeFromFolder(appID: String, folderID: String) {
        guard let (pageIndex, tile) = locate(folderID), var folder = tile.folder,
              folder.bundleIDs.contains(appID) else { return }
        folder.bundleIDs.removeAll { $0 == appID }
        withAnimation(Motion.reorder) {
            guard let index = pages[pageIndex].firstIndex(where: { $0.id == folderID }) else { return }
            if folder.bundleIDs.count >= 2 {
                pages[pageIndex][index] = .makeFolder(folder)
                // The app must go back onto the grid. Previously it was only
                // deleted from the folder, so "从文件夹移出" made it vanish.
                insertTile(.app(appID), page: pageIndex, slot: index + 1)
            } else {
                let replacements = folder.bundleIDs.map { Tile.app($0) } + [.app(appID)]
                pages[pageIndex].remove(at: index)
                pages[pageIndex].insert(contentsOf: replacements,
                                        at: min(index, pages[pageIndex].count))
            }
        }
        openFolderID = nil
        persist()
    }

    // MARK: - UI helpers

    func updateArea(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        // A spring target is expressed in points; it becomes stale if the
        // viewport changes while it is running.
        scrollEngine.cancel()
        areaSize = size
        clampScroll()
    }

    func moveTile(tileID: String, toPage target: Int) {
        guard let (pageIndex, _) = locate(tileID) else { return }
        let destination = min(max(target, 0), max(0, pages.count - 1))
        guard destination != pageIndex else { return }
        guard let sourceIndex = pages[pageIndex].firstIndex(where: { $0.id == tileID }) else { return }
        withAnimation(Motion.reorder) {
            let tile = pages[pageIndex].remove(at: sourceIndex)
            pages[destination].append(tile)
            pages = reflowed(pages)
        }
        clampScroll()
        persist()
    }

    func restoreAutoHidden() {
        guard !hiddenTiles.isEmpty else { return }
        var remaining: [Tile] = []
        var restored: [Tile] = []
        for tile in hiddenTiles {
            if let id = tile.bundleID, manualHidden.contains(id) {
                remaining.append(tile)
            } else {
                restored.append(tile)
            }
        }
        guard !restored.isEmpty else { return }
        hiddenTiles = remaining
        withAnimation(Motion.reorder) {
            if pages.isEmpty { pages = [[]] }
            pages[pages.count - 1].append(contentsOf: restored)
            pages = reflowed(pages)
        }
        clampScroll()
        persist()
    }

    func showSettings() {
        settingsOpen = true
        hiddenOpen = false
        searchOpen = false
        openFolderID = nil
        selection = nil
    }

    func showHidden() {
        hiddenOpen = true
        settingsOpen = false
        searchOpen = false
        openFolderID = nil
        selection = nil
    }

    func closeTransient() {
        searchOpen = false
        setSearchText("")
        searchSelection = 0
        searchField = nil
        settingsOpen = false
        hiddenOpen = false
        openFolderID = nil
        renamingFolderID = nil
        drag = nil
        dragBase = []
        dragBasePage = -1
        dragMotion.value = DragMotion()
        cancelReflow()
        syncDragSemantics()
        press = nil
        selection = nil
        cancelEdgeFlip()
        scrollEngine.cancel()
    }

    func resetLayout() {
        let apps = appsByID.values
            .filter { !manualHidden.contains($0.bundleID) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let tiles = apps.map { Tile.app($0.bundleID) }
        pages = reflowed([tiles])
        scrollPos = 0
        selection = nil
        persist()
    }

    func resetAll() {
        settings = Settings()
        manualHidden = []
        pinned = []
        hiddenTiles = []
        usage = usage.mapValues { _ in Usage() }
        resetLayout()
    }

    // MARK: - Demo helpers (used by --demo-* launch arguments)

    func debugHideSome() {
        let ids = visibleApps.prefix(5).map { $0.bundleID }
        for id in ids { hide(tileID: id) }
    }

    /// Diagnostic only: `--fps-probe` with `LAUNCHOS_DRAG_FPS=1` replays a
    /// real pointer stream through `pointerDown/pointerDragged` once per
    /// display frame, sweeping across the grid. Sweeping (rather than a single
    /// long drag) keeps crossing cell boundaries, which is exactly when the
    /// make-way preview invalidates a rasterised page. A/B against
    /// `LAUNCHOS_NO_LIVE_REFLOW=1` on the same binary.
    func driveProbeDragFrame(_ frame: Int) {
        let m = metrics
        guard pageExtent > 1, let tiles = pages.first, tiles.count > 6 else { return }
        let last = min(tiles.count - 1, max(6, m.capacity - 1))
        let a = m.iconCenter(of: 0)
        let b = m.iconCenter(of: last)
        if frame == 1 {
            pointerDown(at: a)
            pointerDragged(from: a, to: CGPoint(x: a.x + 12, y: a.y + 12))
            return
        }
        let sweep: CGFloat
        if ProbeConfig.dragFast {
            // Worst case: a cell crossing on every single frame.
            let cycle = 96
            let phase = CGFloat((frame - 1) % cycle) / CGFloat(cycle)
            sweep = phase < 0.5 ? phase * 2 : (1 - phase) * 2
        } else {
            // Realistic: 2 pt per frame at 120 Hz, sweeping back and forth.
            let span = max(1, hypot(b.x - a.x, b.y - a.y))
            let travel = CGFloat(frame - 1) * 2.0
            let period = span * 2
            let t = travel.truncatingRemainder(dividingBy: period)
            sweep = t <= span ? t / span : (period - t) / span
        }
        pointerDragged(from: a,
                       to: CGPoint(x: a.x + (b.x - a.x) * sweep,
                                   y: a.y + (b.y - a.y) * sweep))
    }

    func debugMakeFolder() {
        guard let first = pages.first, first.count >= 2,
              let a = first[0].bundleID, let b = first[1].bundleID else { return }
        let folder = Folder(name: "工具", bundleIDs: [a, b])
        withAnimation(Motion.reorder) {
            pages[0].removeFirst(2)
        }
        pages[0].insert(.makeFolder(folder), at: 0)
        openFolderID = folder.id
        persist()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
