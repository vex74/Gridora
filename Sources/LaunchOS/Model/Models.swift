import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI

// MARK: - App

struct AppInfo: Identifiable, Hashable {
    let bundleID: String
    /// Localised display name (Chinese when the bundle provides one).
    let name: String
    let path: String
    /// Compact romanisation of the display name: no spaces or tone marks, so
    /// typing "guanggao" can match 「安卓去广告」.
    let pinyin: String
    /// First letter of every Chinese syllable / English word ("azqgg").
    let pinyinInitials: String
    /// Every name the app is known by (localised, raw, Finder, file name),
    /// lowercase. Search matches these too, so "wechat" still finds 「微信」.
    let aliases: [String]
    /// Compact romanisations and initials of all aliases, precomputed once at
    /// scan time so a query change never runs a string transform per tile.
    let romanizedAliases: [String]
    let romanizedInitials: [String]
    let icon: NSImage

    var id: String { bundleID }
    var url: URL { URL(fileURLWithPath: path) }

    static func == (lhs: AppInfo, rhs: AppInfo) -> Bool { lhs.bundleID == rhs.bundleID }
    func hash(into hasher: inout Hasher) { hasher.combine(bundleID) }

    /// Relevance for a single already-lowercased token. All tokens in a query
    /// must match (AND) and their scores add up, so "google chrome" no longer
    /// surfaces an unrelated app that happens to share one word.
    func searchScore(for tokens: [String]) -> Int {
        var total = 0
        for token in tokens {
            guard let score = score(token) else { return 0 }
            total += score
        }
        return total
    }

    private func score(_ t: String) -> Int? {
        let n = name.lowercased()
        if n == t { return 240 }
        if aliases.contains(where: { $0 == t }) { return 220 }

        // A one-character ASCII token used to hit `n.contains(t)` (160)
        // before any pinyin/initials branch, so "a" or "e" surfaced half the
        // grid ahead of the real match. For those tokens run every
        // high-confidence path first and demote substring matches instead of
        // dropping them, so short queries still find apps by substring.
        if t.count == 1, t.unicodeScalars.allSatisfy({ $0.value < 128 }) {
            if n.hasPrefix(t) { return 200 }
            if aliases.contains(where: { $0.hasPrefix(t) }) { return 180 }
            if pinyinInitials == t { return 155 }
            if pinyin == t { return 150 }
            if pinyin.hasPrefix(t) { return 120 }
            if romanizedInitials.contains(where: { $0 == t }) { return 115 }
            if pinyinInitials.hasPrefix(t) { return 110 }
            if romanizedAliases.contains(where: { $0 == t }) { return 105 }
            if romanizedInitials.contains(where: { $0.hasPrefix(t) }) { return 70 }
            if romanizedAliases.contains(where: { $0.hasPrefix(t) }) { return 60 }
            if n.contains(t) { return 90 }
            if aliases.contains(where: { $0.contains(t) }) { return 55 }
            if pinyin.contains(t) { return 45 }
            if romanizedAliases.contains(where: { $0.contains(t) }) { return 25 }
            return nil
        }

        if n.hasPrefix(t) { return 200 }
        if aliases.contains(where: { $0.hasPrefix(t) }) { return 180 }
        if n.contains(t) { return 160 }
        if pinyinInitials == t { return 155 }
        if pinyin == t { return 150 }
        if pinyin.hasPrefix(t) { return 120 }
        if romanizedInitials.contains(where: { $0 == t }) { return 115 }
        if pinyinInitials.hasPrefix(t) { return 110 }
        if romanizedAliases.contains(where: { $0 == t }) { return 105 }
        if aliases.contains(where: { $0.contains(t) }) { return 100 }
        if pinyin.contains(t) { return 75 }
        if romanizedInitials.contains(where: { $0.hasPrefix(t) }) { return 70 }
        if romanizedAliases.contains(where: { $0.hasPrefix(t) }) { return 60 }
        if romanizedAliases.contains(where: { $0.contains(t) }) { return 40 }
        // Last resort only. Very short tokens ("gg") match almost any bundle
        // id, and Chrome PWA shortcuts carry "com.google.Chrome.app.<hash>".
        if t.count >= 3, bundleID.lowercased().contains(t) { return 10 }
        return nil
    }
}

// MARK: - Folder

struct Folder: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var bundleIDs: [String]

    init(id: String = UUID().uuidString, name: String = "文件夹", bundleIDs: [String] = []) {
        self.id = id
        self.name = name
        self.bundleIDs = bundleIDs
    }
}

// MARK: - Tile (an app or a folder on the grid)

struct Tile: Codable, Hashable, Identifiable {
    var id: String
    var bundleID: String?
    var folder: Folder?

    var isFolder: Bool { folder != nil }

    static func app(_ bundleID: String) -> Tile {
        Tile(id: bundleID, bundleID: bundleID, folder: nil)
    }

    static func makeFolder(_ folder: Folder) -> Tile {
        Tile(id: folder.id, bundleID: nil, folder: folder)
    }
}

// MARK: - Usage

struct Usage: Codable {
    var launches: Int = 0
    var lastLaunch: Date?
    var firstSeen: Date = Date()
}

// MARK: - Search glass

/// The two real `NSGlassEffectView.Style` values. `.identity` is deliberately
/// excluded: a "glass" that renders nothing would be a fake toggle.
enum SearchGlassStyle: String, Codable, CaseIterable, Identifiable {
    case regular
    case clear

    var id: String { rawValue }
    var label: String { self == .regular ? "常规" : "通透" }
}

// MARK: - Grid insets

/// Which edge a settings slider controls.
enum GridInsetSide {
    case top, bottom, left, right
}

/// Persisted per-edge insets as fractions of the shorter page dimension.
/// This is the single source of truth for layout. `Settings.gridInset` is
/// kept only as a legacy mirror for builds that know one value.
struct GridInsets: Codable, Equatable {
    var top: Double = 0
    var left: Double = 0
    var bottom: Double = 0
    var right: Double = 0

    static func uniform(_ value: Double) -> GridInsets {
        GridInsets(top: value, left: value, bottom: value, right: value)
    }

    var average: Double { (top + left + bottom + right) / 4 }

    func clamped(to range: ClosedRange<Double>) -> GridInsets {
        func c(_ v: Double) -> Double {
            min(max(v.isFinite ? v : range.lowerBound, range.lowerBound), range.upperBound)
        }
        return GridInsets(top: c(top), left: c(left), bottom: c(bottom), right: c(right))
    }

    mutating func set(_ side: GridInsetSide, _ value: Double) {
        let range = Settings.gridInsetRange
        let v = min(max(value.isFinite ? value : range.lowerBound, range.lowerBound),
                    range.upperBound)
        switch side {
        case .top: top = v
        case .bottom: bottom = v
        case .left: left = v
        case .right: right = v
        }
    }
}

/// Point-space counterpart consumed by GridMetrics.
struct GridEdgeInsets: Equatable {
    var top: CGFloat = 0
    var left: CGFloat = 0
    var bottom: CGFloat = 0
    var right: CGFloat = 0

    static let zero = GridEdgeInsets()
}

// MARK: - Settings

struct Settings: Codable, Equatable {
    var columns: Int = 7
    var rows: Int = 5
    var iconScale: Double = 1.0
    var showLabels: Bool = true
    var vertical: Bool = false
    var autoHideUnused: Bool = false
    var autoHideDays: Int = 30
    var backgroundDim: Double = 0.42
    var backgroundBlur: Double = 55
    /// Master scroll sensitivity. Scales trackpad deltas, the short-flick
    /// paging threshold and the spring's time axis (ScrollEngine.pace).
    var scrollSpeed: Double = 1.0
    var reverseScroll: Bool = false
    var useWallpaper: Bool = false
    /// Discrete mouse wheel: one page per N NSEvents (notches), so it does not
    /// depend on how many points the hardware reports for one notch.
    var wheelLines: Int = 1
    var launchAtLogin: Bool = false
    var extraFolders: [String] = []
    /// Optional wallpaper picked by the user. When set, it wins over the
    /// system wallpaper detection (which fails for image-folder wallpapers on
    /// some macOS 15 setups). Persisted as an absolute path; the app is not
    /// sandboxed, so no security-scoped bookmark is needed.
    var wallpaperPath: String? = nil
    /// Legacy single-value mirror written for older builds. Layout never
    /// reads this; `gridInsets` is the single source of truth. UI writes keep
    /// it equal to the four-edge average so an old LaunchOS opening a new
    /// state.json still sees a sane uniform margin.
    var gridInset: Double = 0.0
    /// Per-edge inset of the icon grid, as a fraction of the shorter page
    /// dimension. 0 = edge to edge, 0.18 = noticeably roomy.
    var gridInsets = GridInsets()
    /// Tear the process down when the launcher closes. Default OFF: a Carbon
    /// `EventHotKey` belongs to the process that registered it, so exiting on
    /// hide made every configurable start key (F3, ⌃⌥Space …) stop working
    /// until the user clicked the Dock icon again. Staying resident with
    /// `LSUIElement` / `.accessory` has no visible cost: no Dock tile, no
    /// running indicator, no menu bar takeover. Users who explicitly want a
    /// cold start on every open can still switch this on in Settings ▸ General.
    var quitOnHide: Bool = false
    /// Marks a state file that was written after the residency default changed.
    /// Older files have no key: their `quitOnHide: true` was the old factory
    /// default, not a deliberate choice, so it must not keep killing the
    /// global hotkey. Encoded as 1 from now on; decode treats 0 as "upgrade".
    var residencyChoiceVersion: Int = 1
    /// Claim a Dock tile at runtime. Default false = transient-panel shape
    /// (LSUIElement / .accessory): the pinned Dock icon never bounces, no
    /// running indicator, no menu bar takeover. Old state files predate this
    /// switch, so they get the quiet behaviour. Reversible in General.
    var showInDock: Bool = false

    /// macOS 26+ Liquid Glass for the search surface: field, results panel
    /// and the full-screen fog. Old state files have no key and get the new
    /// look; below macOS 26 the view falls back to a material + dark tint.
    var searchGlassEnabled: Bool = true
    var searchGlassStyle: SearchGlassStyle = .regular
    /// Dark tint laid over the glass so white search text stays legible on a
    /// bright wallpaper. 0 = pure system glass.
    var searchGlassTint: Double = Settings.defaultSearchGlassTint
    /// Corner radius shared by the field and the results panel, in points.
    var searchGlassRadius: Double = Settings.defaultSearchGlassRadius
    /// Dimming behind the glass; replaces the old hard-coded 0.26 black scrim.
    var searchScrim: Double = Settings.defaultSearchScrim

    /// macOS 26+ Liquid Glass for the open folder panel. Independent of the
    /// search surface: the folder is far larger, carries white labels and has
    /// its own 24 pt panel radius, so it ships with a deeper tint. All five
    /// values are adjustable in Settings ▸ Appearance, and toggling it off
    /// restores the original near-black panel. Old state files have none of
    /// these keys and get the new glass look.
    var folderGlassEnabled: Bool = true
    var folderGlassStyle: SearchGlassStyle = .regular
    var folderGlassTint: Double = Settings.defaultFolderGlassTint
    var folderGlassRadius: Double = Settings.defaultFolderGlassRadius
    /// Dimming of the full-screen sheet behind the folder panel; replaces the
    /// old hard-coded 0.28 black scrim.
    var folderGlassScrim: Double = Settings.defaultFolderGlassScrim

    /// User-recordable shortcuts. Old state files have none of these keys and
    /// get exactly the chords older builds hard-wired, so an upgrade never
    /// changes the keys a user already knows. `KeyChord` is the single source
    /// of truth for matching, labels and Carbon registration.
    var launcherHotKey = KeyChord.defaultLauncher
    var previousPageHotKey = KeyChord.defaultPreviousPage
    var nextPageHotKey = KeyChord.defaultNextPage
    /// User-recordable shortcut that opens search. Old state files have no key
    /// and get ⌘F.
    var searchHotKey = SearchHotKey.default
    /// Typing a letter over the icon grid used to open search and inject that
    /// letter into a field that did not exist yet -- the main source of lost
    /// first characters and IME races. Off by default: use the shortcut.
    var letterOpensSearch: Bool = false

    static let gridInsetRange: ClosedRange<Double> = 0...0.18
    static let searchGlassTintRange: ClosedRange<Double> = 0...0.75
    static let searchGlassRadiusRange: ClosedRange<Double> = 6...28
    static let searchScrimRange: ClosedRange<Double> = 0...0.60
    static let defaultSearchGlassTint: Double = 0.32
    static let defaultSearchGlassRadius: Double = 14
    static let defaultSearchScrim: Double = 0.26

    static let folderGlassTintRange: ClosedRange<Double> = 0...0.75
    static let folderGlassRadiusRange: ClosedRange<Double> = 8...36
    static let folderGlassScrimRange: ClosedRange<Double> = 0...0.60
    /// The folder radius starts at the shared panel radius; AppearanceProbe
    /// asserts the two never drift apart.
    static let defaultFolderGlassRadius: Double = Double(DesignTokens.panelRadius)
    static let defaultFolderGlassTint: Double = 0.38
    static let defaultFolderGlassScrim: Double = 0.28

    /// Single source of truth for the icon-size slider. The upper bound is
    /// 140% because the cell headroom clamp in GridMetrics.iconSize already
    /// saturates at ~137% on an 8x7 grid; anything above that is a no-op.
    static let iconScaleRange: ClosedRange<Double> = 0.78...1.4

    init() {}

    enum CodingKeys: String, CodingKey {
        case columns, rows, iconScale, showLabels, vertical
        case autoHideUnused, autoHideDays, backgroundDim, backgroundBlur
        case scrollSpeed, reverseScroll, useWallpaper
        case wheelLines, launchAtLogin, extraFolders, wallpaperPath, gridInset, gridInsets, quitOnHide, showInDock
        case residencyChoiceVersion
        case searchGlassEnabled, searchGlassStyle, searchGlassTint, searchGlassRadius, searchScrim
        case folderGlassEnabled, folderGlassStyle, folderGlassTint, folderGlassRadius, folderGlassScrim
        case launcherHotKey, previousPageHotKey, nextPageHotKey
        case searchHotKey, letterOpensSearch
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        columns = try c.decodeIfPresent(Int.self, forKey: .columns) ?? 7
        rows = try c.decodeIfPresent(Int.self, forKey: .rows) ?? 5
        // Clamp on load so a state.json written by an older build (which
        // allowed 200%) can never leave the slider and the stored value
        // disagreeing after the upper bound was lowered.
        let decodedScale = try c.decodeIfPresent(Double.self, forKey: .iconScale) ?? 1.0
        iconScale = min(max(decodedScale, Settings.iconScaleRange.lowerBound),
                        Settings.iconScaleRange.upperBound)
        showLabels = try c.decodeIfPresent(Bool.self, forKey: .showLabels) ?? true
        vertical = try c.decodeIfPresent(Bool.self, forKey: .vertical) ?? false
        autoHideUnused = try c.decodeIfPresent(Bool.self, forKey: .autoHideUnused) ?? false
        autoHideDays = try c.decodeIfPresent(Int.self, forKey: .autoHideDays) ?? 30
        backgroundDim = try c.decodeIfPresent(Double.self, forKey: .backgroundDim) ?? 0.42
        backgroundBlur = try c.decodeIfPresent(Double.self, forKey: .backgroundBlur) ?? 55
        scrollSpeed = try c.decodeIfPresent(Double.self, forKey: .scrollSpeed) ?? 1.0
        reverseScroll = try c.decodeIfPresent(Bool.self, forKey: .reverseScroll) ?? false
        useWallpaper = try c.decodeIfPresent(Bool.self, forKey: .useWallpaper) ?? false
        wheelLines = try c.decodeIfPresent(Int.self, forKey: .wheelLines) ?? 1
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        extraFolders = try c.decodeIfPresent([String].self, forKey: .extraFolders) ?? []
        wallpaperPath = try c.decodeIfPresent(String.self, forKey: .wallpaperPath)
        let legacyInset = clamp(try c.decodeIfPresent(Double.self, forKey: .gridInset) ?? 0.0,
                                to: Settings.gridInsetRange)
        if let perEdge = try c.decodeIfPresent(GridInsets.self, forKey: .gridInsets) {
            gridInsets = perEdge.clamped(to: Settings.gridInsetRange)
        } else {
            // Old state files have only one value: fan it out to all four
            // edges so the rendered layout is identical after the upgrade.
            gridInsets = GridInsets.uniform(legacyInset)
        }
        gridInset = gridInsets.average
        // One-time residency upgrade. Older state files stored the factory
        // `quitOnHide: true`, which unregistered the global start key as soon
        // as the launcher hid. Treat any file without the version marker as
        // "never explicitly chosen" and upgrade it to resident mode. A user
        // who later flips the switch writes version 1 and is respected.
        let storedResidencyVersion = try c.decodeIfPresent(Int.self, forKey: .residencyChoiceVersion) ?? 0
        residencyChoiceVersion = 1
        quitOnHide = try c.decodeIfPresent(Bool.self, forKey: .quitOnHide) ?? false
        if storedResidencyVersion < 1 { quitOnHide = false }
        // Old state files also predate the Dock switch; they get the quiet shape.
        showInDock = try c.decodeIfPresent(Bool.self, forKey: .showInDock) ?? false
        searchGlassEnabled = try c.decodeIfPresent(Bool.self, forKey: .searchGlassEnabled) ?? true
        // Decode as a raw string: a corrupt enum value must not take down the
        // whole state file the way decodeIfPresent(Enum.self) would.
        let styleRaw = try c.decodeIfPresent(String.self, forKey: .searchGlassStyle) ?? ""
        searchGlassStyle = SearchGlassStyle(rawValue: styleRaw) ?? .regular
        searchGlassTint = clamp(try c.decodeIfPresent(Double.self, forKey: .searchGlassTint)
                                ?? Settings.defaultSearchGlassTint,
                                to: Settings.searchGlassTintRange)
        searchGlassRadius = clamp(try c.decodeIfPresent(Double.self, forKey: .searchGlassRadius)
                                  ?? Settings.defaultSearchGlassRadius,
                                  to: Settings.searchGlassRadiusRange)
        searchScrim = clamp(try c.decodeIfPresent(Double.self, forKey: .searchScrim)
                            ?? Settings.defaultSearchScrim,
                            to: Settings.searchScrimRange)
        folderGlassEnabled = try c.decodeIfPresent(Bool.self, forKey: .folderGlassEnabled) ?? true
        // Same raw-string decode as the search surface: a corrupt style must
        // not take down the whole state file.
        let folderStyleRaw = try c.decodeIfPresent(String.self, forKey: .folderGlassStyle) ?? ""
        folderGlassStyle = SearchGlassStyle(rawValue: folderStyleRaw) ?? .regular
        folderGlassTint = clamp(try c.decodeIfPresent(Double.self, forKey: .folderGlassTint)
                                ?? Settings.defaultFolderGlassTint,
                                to: Settings.folderGlassTintRange)
        folderGlassRadius = clamp(try c.decodeIfPresent(Double.self, forKey: .folderGlassRadius)
                                  ?? Settings.defaultFolderGlassRadius,
                                  to: Settings.folderGlassRadiusRange)
        folderGlassScrim = clamp(try c.decodeIfPresent(Double.self, forKey: .folderGlassScrim)
                                 ?? Settings.defaultFolderGlassScrim,
                                 to: Settings.folderGlassScrimRange)
        // Shortcuts are resolved in priority order. A missing, corrupt or
        // colliding stored value falls back to that role's shipped default,
        // then to a safe alternate: no state file can leave two roles fighting
        // over one physical chord, or make the launcher unreachable.
        // `decode` (not decodeIfPresent) inside `try?` also covers JSON null.
        let storedLauncher = try? c.decode(KeyChord.self, forKey: .launcherHotKey)
        let storedPrevious = try? c.decode(KeyChord.self, forKey: .previousPageHotKey)
        let storedNext = try? c.decode(KeyChord.self, forKey: .nextPageHotKey)
        let storedSearch = try? c.decode(KeyChord.self, forKey: .searchHotKey)
        var claimed: [KeyChord] = []

        func claim(_ stored: KeyChord?, role: HotKeyRole) -> KeyChord {
            let candidates = [stored].compactMap { $0 }
                + [role.defaultChord, role.alternateChord]
            for candidate in candidates
                where candidate.isValid(allowsBareKeys: role.allowsBareKeys,
                                        allowsBareFunctionKeys: role.allowsBareFunctionKeys)
                    && !claimed.contains(where: { candidate.hasSameCombo(as: $0) }) {
                claimed.append(candidate)
                return candidate
            }
            // Practically unreachable last resort: keeps the four roles
            // distinct even for a deliberately hostile state.json.
            let emergency = KeyChord(keyCode: KeyChord.defaultSearch.keyCode,
                                     modifiers: UInt32(cmdKey | controlKey | optionKey | shiftKey),
                                     label: "⇧⌥⌃⌘F")
            claimed.append(emergency)
            return emergency
        }

        launcherHotKey = claim(storedLauncher, role: .launcher)
        // The shipped ⌃⌥Space still carries the two legacy spare chords; those
        // are occupied for every other role until the launcher key is changed.
        if launcherHotKey.hasSameCombo(as: .defaultLauncher) {
            claimed.append(contentsOf: KeyChord.legacyAlternates)
        }
        previousPageHotKey = claim(storedPrevious, role: .previousPage)
        nextPageHotKey = claim(storedNext, role: .nextPage)
        searchHotKey = claim(storedSearch, role: .search)
        // Old state files get the safe behaviour: letters no longer open search.
        letterOpensSearch = try c.decodeIfPresent(Bool.self, forKey: .letterOpensSearch) ?? false
    }

    private func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value.isFinite ? value : range.lowerBound, range.lowerBound), range.upperBound)
    }
}

// MARK: - Persisted state

struct PersistedState: Codable {
    var pages: [[Tile]] = []
    var hidden: [Tile] = []
    var settings: Settings = Settings()
    var usage: [String: Usage] = [:]
    var manualHidden: [String] = []
    var pinned: [String] = []
}

// MARK: - Grid geometry

struct GridMetrics {
    var size: CGSize
    var cols: Int
    var rows: Int
    var iconScale: Double
    var showsLabels: Bool = true
    /// Distance from each edge of `size` to the icon grid. Tiles are drawn
    /// with `center(of:)` and hit tests go through `index(at:)`/`iconIndex`,
    /// so keeping the offsets here keeps drawing and hit testing in lockstep
    /// without touching the paging layer. Each edge is independent.
    var insets: GridEdgeInsets = .zero

    /// Legacy single-value alias read by diagnostics (left edge).
    var inset: CGFloat { insets.left }

    private var gridSize: CGSize {
        CGSize(width: max(1, size.width - insets.left - insets.right),
               height: max(1, size.height - insets.top - insets.bottom))
    }

    var cellW: CGFloat { gridSize.width / CGFloat(max(cols, 1)) }
    var cellH: CGFloat { gridSize.height / CGFloat(max(rows, 1)) }
    var capacity: Int { max(cols, 1) * max(rows, 1) }

    var iconSize: CGFloat {
        // The tile is: icon frame (iconSize + 18) + VStack spacing 6 + label
        // (labelHeight + 4). On a 9x7 grid the old headroom of only 30 pt let
        // a 140% icon grow to 216 pt inside a 176 pt cell, overlapping the row
        // below; the old min(raw, limit) also saturated above ~137%, so the
        // last third of the slider did nothing. Map the *whole* slider range
        // onto the space that actually fits, so every step changes the icon
        // and 140% exactly fills the cell without overflowing it.
        let chrome: CGFloat = showsLabels ? 18 + 6 + labelHeight + 4 : 18 + 8
        let limit = max(40, min(cellW - 12, cellH - chrome))
        let upper = CGFloat(Settings.iconScaleRange.upperBound)
        return max(40, min(limit, limit * CGFloat(iconScale) / upper))
    }

    var labelHeight: CGFloat { 20 }

    /// Half-size of the artwork hit box. Clamped to the cell so a deliberately
    /// oversized icon can never swallow its neighbours' clicks or drags.
    var iconHitHalf: CGFloat {
        max(12, min(iconSize / 2 + 5, min(cellW, cellH) / 2 - 2))
    }

    /// Vertical offset of the icon inside its cell (the label sits below it).
    private var iconOffsetY: CGFloat {
        guard showsLabels else { return 0 }
        return -(6 + 19) / 2
    }

    func center(of index: Int) -> CGPoint {
        guard cols > 0, rows > 0 else { return .zero }
        let col = index % cols
        let row = index / cols
        return CGPoint(x: insets.left + (CGFloat(col) + 0.5) * cellW,
                       y: insets.top + (CGFloat(row) + 0.5) * cellH)
    }

    /// Centre of the actual icon artwork (not the whole cell).
    func iconCenter(of index: Int) -> CGPoint {
        let c = center(of: index)
        return CGPoint(x: c.x, y: c.y + iconOffsetY)
    }

    func index(at point: CGPoint) -> Int {
        guard cols > 0, rows > 0 else { return 0 }
        let local = CGPoint(x: point.x - insets.left, y: point.y - insets.top)
        let col = Int(floor(local.x / cellW))
        let row = Int(floor(local.y / cellH))
        let c = min(max(col, 0), cols - 1)
        let r = min(max(row, 0), rows - 1)
        return r * cols + c
    }

    /// Returns the tile index only when the point is really on the icon art.
    /// Launchpad does not activate a tile from the empty space around it.
    func iconIndex(at point: CGPoint, count: Int) -> Int? {
        guard count > 0, cols > 0, rows > 0, contains(point) else { return nil }
        let local = CGPoint(x: point.x - insets.left, y: point.y - insets.top)
        let col = Int(floor(local.x / cellW))
        let row = Int(floor(local.y / cellH))
        guard col >= 0, col < cols, row >= 0, row < rows else { return nil }
        let index = row * cols + col
        guard index < count else { return nil }
        let c = iconCenter(of: index)
        let half = iconHitHalf
        guard abs(point.x - c.x) <= half, abs(point.y - c.y) <= half else { return nil }
        return index
    }

    func contains(_ point: CGPoint) -> Bool {
        point.x >= insets.left && point.y >= insets.top
            && point.x <= size.width - insets.right
            && point.y <= size.height - insets.bottom
    }
}

// MARK: - Drag state

struct DragState {
    var tileID: String
    var page: Int
    var location: CGPoint      // cursor, pager-container coordinates
    var grab: CGSize           // (tile center - cursor) in page coordinates
    var active: Bool
    var mergeTarget: String?
    var mergeSlot: Int?        // grid cell of the merge target in the drag-start snapshot
    /// Index the dragged tile held when the drag began. The live make-way
    /// preview shifts every other tile relative to this index.
    var sourceIndex: Int?
    /// Slot the dragged tile would land in, published only while the pointer
    /// is over a gap (no merge target). `nil` means the grid stays frozen so a
    /// merge target does not slide out from under the artwork.
    var insertionSlot: Int?
    var velocity: CGFloat
    var lastLocation: CGPoint
}

// MARK: - Paging state

/// The paging offset changes on every animation frame. `position` is the only
/// high-frequency published value in the app: a page transition re-evaluates
/// just the pager, never the whole view tree.
@MainActor
final class ScrollState: ObservableObject {
    @Published var position: CGFloat = 0
}

/// Low-frequency companion. Views that need only the settled page (page dots,
/// selection highlight) observe this, so crossing a page boundary no longer
/// invalidates every icon in the grid.
@MainActor
final class PageState: ObservableObject {
    @Published var index: Int = 0
}

// MARK: - Drag state, split by update frequency

struct DragSemantics: Equatable {
    var active = false
    var sourceID: String?
    var targetID: String?
    var slot: Int?
    var page: Int?
    var sourceIndex: Int?
    /// nil while hovering a merge target: the grid must stay put then.
    var insertionSlot: Int?
}

/// Published only when a drag starts / ends / changes page or merge target.
/// Every tile observes this, but a 120 Hz pointer stream does not publish here.
@MainActor
final class DragSemanticState: ObservableObject {
    @Published var value = DragSemantics()
}

struct DragMotion: Equatable {
    var location: CGPoint = .zero
    var velocity: CGFloat = 0
    var grab: CGSize = .zero
}

/// Pointer position, velocity and grab offset while dragging. Only the
/// floating tile layer observes this; a single published value means exactly
/// one invalidation per pointer event.
@MainActor
final class DragMotionState: ObservableObject {
    @Published var value = DragMotion()
}

// MARK: - Folder drag state (split by update frequency)

/// Low-frequency facts about a drag out of an open folder. The folder panel
/// observes this to fade itself out; it does NOT observe pointer movement.
@MainActor
final class FolderDragInfo: ObservableObject {
    @Published var appID: String?
    @Published var folderID: String?
    @Published var outsidePanel = false
    /// Slot (within the currently shown 3 × 3 page) the app would land on if
    /// released inside the panel. Published only when the cell changes, so the
    /// folder grid re-evaluates on cell crossings, not on every pointer event.
    @Published var dropSlot: Int?
}

/// High-frequency pointer position. Only the floating icon layer subscribes,
/// so dragging out of a folder never re-evaluates the folder grid or the
/// 165-tile pager behind it.
@MainActor
final class FolderDragMotion: ObservableObject {
    @Published var position: CGPoint = .zero
}

// MARK: - Motion

enum Motion {
    /// `.impeccable.md` §5 requires a full motion downgrade when the system's
    /// "Reduce motion" preference is on. AppDelegate sets this at launch and
    /// refreshes it when the preference changes; every animation below is a
    /// computed property so a single switch covers the whole app.
    /// The paging spring is intentionally NOT switched off: it is direct
    /// manipulation of the grid by the user's own gesture, not decoration.
    static var reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    static var snap: Animation {
        reduceMotion ? .linear(duration: 0.001)
                     : .spring(response: 0.45, dampingFraction: 0.93)
    }
    static var reorder: Animation {
        reduceMotion ? .linear(duration: 0.001)
                     : .spring(response: 0.26, dampingFraction: 0.90)
    }
    static var panel: Animation {
        reduceMotion ? .linear(duration: 0.001)
                     : .spring(response: 0.36, dampingFraction: 0.88)
    }
    static var quick: Animation {
        reduceMotion ? .linear(duration: 0.001) : .easeOut(duration: 0.16)
    }
    /// Shared by the window fade and the content transform so show / hide
    /// never split into two different timings.
    static var windowDuration: TimeInterval { reduceMotion ? 0.001 : 0.20 }

    /// macOS 15 Launchpad: a plain cross-fade of the whole overlay. The icon
    /// grid neither scales nor moves, so these durations only animate window
    /// alpha on the compositor — SwiftUI still changes exactly once, which is
    /// what removed the 44–166 ms cold-launch long frames. Out is slightly
    /// quicker than in, matching Launchpad's dismiss.
    static var fadeInDuration: TimeInterval { reduceMotion ? 0.001 : 0.24 }
    static var fadeOutDuration: TimeInterval { reduceMotion ? 0.001 : 0.20 }

    /// Kept only for `LAUNCHOS_OPEN_ANIM=scale`, the old centre-out reveal
    /// that is still useful as a one-variable A/B control. Unlike
    /// `windowDuration`, it lives on the content layer, not in a SwiftUI
    /// transaction; the longer duration is what made the expansion read as an
    /// expansion. It is no longer the shipped look.
    static var openDuration: TimeInterval { reduceMotion ? 0.001 : 0.30 }
    static let openStartScale: CGFloat = 0.72

    /// Critically damped spring used by the display-linked paging engine.
    /// sqrt(360) ≈ 19 rad/s: 90% of a page in ~0.21 s, visually settled by
    /// ~0.38 s, fully at rest by ~0.65 s. Verified by numerical integration
    /// at both 60 and 120 Hz and at dt = 1/30 (dropped frames): no overshoot,
    /// no oscillation. The earlier 190/27.6 pair needed ~0.85 s and felt mushy.
    static let pageStiffness: CGFloat = 360
    static let pageDamping: CGFloat = 38
    /// Residual gesture velocity handed to the spring, clamped (points/s).
    /// 6000 × 0.14 s look-ahead ≈ 840 pt, enough for a fast flick to choose
    /// the next page instead of always snapping back to the nearest one.
    static let maxSettleVelocity: CGFloat = 6000
}
