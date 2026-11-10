import AppKit
import Foundation

/// One snapshot of the *arrangement only*. Settings, usage counters and the
/// wallpaper are deliberately excluded: those are per-Mac preferences, while
/// the icon order, page breaks, folders and hidden apps are what a user means
/// by "sync my layout".
struct SyncedLayout: Codable {
    var version: Int
    var updatedAt: Date
    var deviceName: String
    var pages: [[Tile]]
    var hidden: [Tile]
    var manualHidden: [String]
    var pinned: [String]
}

/// iCloud Drive layout sync via a single JSON snapshot. iCloud does the
/// transport, so no CloudKit container, entitlement, account or server is
/// required (the app is ad-hoc signed and cannot carry iCloud entitlements).
///
/// The file is the source of truth for *which* arrangement is newest:
///   - every local change refreshes `localUpdatedAt` and pushes after 1 s of
///     quiet (so a drag does not write to iCloud on every pointer event);
///   - a 12 s poll plus a check on every app activation pulls newer snapshots;
///   - newest `updatedAt` wins, which is the only sane rule for a layout that
///     is edited on one Mac at a time.
///
/// iCloud-specific hardening:
///   - all reads/writes go through NSFileCoordinator. Writing a plain
///     `Data.write(to:)` into iCloud Drive bypasses coordination and is the
///     usual cause of conflict copies and lost edits across Macs.
///   - "Optimize Mac Storage" can evict the snapshot to a `.<name>.icloud`
///     placeholder. Treating that as "no file" would push this Mac's stale
///     layout over the good cloud copy, so writes are held until it downloads.
///   - the Settings page shows whether iCloud Drive is actually connected.
///
/// Off by default. Nothing outside the app's own state is touched until the
/// user enables it in Settings → 同步.
@MainActor
final class LayoutSync: ObservableObject {

    static let shared = LayoutSync()

    private enum Key {
        static let enabled = "launchos.sync.enabled"
        static let folderPath = "launchos.sync.folderPath"
        static let localUpdatedAt = "launchos.sync.localUpdatedAt"
        static let lastPull = "launchos.sync.lastPull"
    }

    /// Probes run with LAUNCHOS_STATE_DIR / LAUNCHOS_SYNC_DIR overrides. Those
    /// isolate file I/O, but UserDefaults.standard is shared with the real
    /// app: an attach() from a probe would otherwise stamp `localUpdatedAt`
    /// and change which layout wins on the next real launch. Probe runs keep
    /// every sync preference in memory instead.
    private final class SyncDefaults {
        private let isolated = ProcessInfo.processInfo.environment["LAUNCHOS_STATE_DIR"] != nil
        private let backing = UserDefaults.standard
        private var memory: [String: Any] = [:]

        func object(forKey key: String) -> Any? {
            isolated ? memory[key] : backing.object(forKey: key)
        }
        func string(forKey key: String) -> String? {
            isolated ? memory[key] as? String : backing.string(forKey: key)
        }
        func bool(forKey key: String) -> Bool {
            isolated ? (memory[key] as? Bool) ?? false : backing.bool(forKey: key)
        }
        func set(_ value: Any?, forKey key: String) {
            if isolated { memory[key] = value; return }
            if let value { backing.set(value, forKey: key) }
            else { backing.removeObject(forKey: key) }
        }
        func removeObject(forKey key: String) {
            if isolated { memory.removeValue(forKey: key) }
            else { backing.removeObject(forKey: key) }
        }
    }

    private let fileName = "LaunchOS-layout.json"
    private let defaults = SyncDefaults()

    @Published private(set) var status = "未开启"
    @Published private(set) var folderDescription = ""
    @Published private(set) var iCloudBadge = ""
    @Published private(set) var isEnabled: Bool = false

    private weak var model: LauncherModel?
    private var pushWork: DispatchWorkItem?
    private var pollTimer: Timer?
    private var lastSeenModification: Date?
    /// Suppresses the push triggered by persist() while a remote snapshot is
    /// being applied, otherwise the two Macs would bounce the same file back
    /// and forth forever.
    private var applyingRemote = false
    /// iCloud has evicted the snapshot; hold every write until it materialises.
    private var awaitingDownload = false
    private var pendingPushRetry = false

    private init() {
        isEnabled = defaults.bool(forKey: Key.enabled)
    }

    // MARK: - Locations

    /// `LAUNCHOS_SYNC_DIR` is a diagnostic override used by the sync probes;
    /// in normal use it is never set.
    private var folderURL: URL {
        if let override = ProcessInfo.processInfo.environment["LAUNCHOS_SYNC_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let path = defaults.string(forKey: Key.folderPath), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs",
                                    isDirectory: true)
            .appendingPathComponent("LaunchOS", isDirectory: true)
    }

    private var fileURL: URL { folderURL.appendingPathComponent(fileName) }

    /// An evicted iCloud Drive item is kept as ".<original name>.icloud".
    private var placeholderURL: URL {
        folderURL.appendingPathComponent("." + fileName + ".icloud")
    }

    private var deviceName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    private var isICloudFolder: Bool {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents", isDirectory: true).path
        return folderURL.path.hasPrefix(root + "/")
    }

    /// The com~apple~CloudDocs directory only exists once the user is signed
    /// in and iCloud Drive is enabled. `ubiquityIdentityToken` is nil for an
    /// ad-hoc, non-sandboxed app, so it cannot be used as a test here.
    private var iCloudDriveReady: Bool {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs",
                                    isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue,
              fm.isWritableFile(atPath: root.path) else { return false }
        return true
    }

    private func badge(forCloudFolder: Bool, ready: Bool) -> String {
        if !forCloudFolder { return "自定义文件夹 · 由该目录所属云盘负责同步" }
        if ready { return "iCloud Drive · 已连接，由系统在后台上传" }
        return "iCloud Drive 未就绪（未登录或未开启），快照仅留在本机"
    }

    private func refreshFolderDescription() {
        folderDescription = (folderURL.path as NSString).abbreviatingWithTildeInPath
        iCloudBadge = badge(forCloudFolder: isICloudFolder, ready: iCloudDriveReady)
    }

    private func timeString(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private var uploadedVerb: String {
        isICloudFolder && iCloudDriveReady ? "已同步到 iCloud Drive" : "已上传到同步文件夹"
    }

    // MARK: - Lifecycle

    func attach(model: LauncherModel) {
        self.model = model
        refreshFolderDescription()
        guard isEnabled else {
            status = "未开启"
            return
        }
        reconcileOnLaunch()
        startPolling()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Key.enabled)
        if enabled {
            // Do NOT stamp localUpdatedAt here. On a Mac that has never
            // synced, an existing snapshot must win; stamping "now" would
            // silently overwrite the other Mac's arrangement on enable.
            refreshFolderDescription()
            reconcileOnLaunch()
            startPolling()
        } else {
            stopPolling()
            pushWork?.cancel()
            pushWork = nil
            awaitingDownload = false
            pendingPushRetry = false
            status = "未开启"
        }
    }

    /// Called whenever the launcher becomes active: iCloud may have delivered
    /// a file while the app was hidden, and a 12 s poll would feel sluggish.
    func checkRemote() {
        guard isEnabled, !applyingRemote else { return }
        // An evicted snapshot must never be read as "no file". If we were
        // waiting for it, replay the timestamp comparison once it has landed:
        // a layout edited locally during the wait is newer and gets pushed.
        if awaitingDownload {
            if hasPendingDownload { _ = triggerDownloadIfNeeded(); return }
            awaitingDownload = false
            reconcileOnLaunch()
            return
        }
        if triggerDownloadIfNeeded() { return }
        if pendingPushRetry {
            pendingPushRetry = false
            push()
            return
        }
        guard let remote = readRemote() else { return }
        let modified = modificationDate()
        if let seen = lastSeenModification, let modified, modified <= seen { return }
        lastSeenModification = modified
        let localStamp = defaults.object(forKey: Key.localUpdatedAt) as? Date ?? .distantPast
        if remote.updatedAt > localStamp.addingTimeInterval(0.5) {
            apply(remote)
        }
    }

    private func startPolling() {
        stopPolling()
        let timer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkRemote() }
        }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func reconcileOnLaunch() {
        refreshFolderDescription()
        if triggerDownloadIfNeeded() { return }
        let localStamp = defaults.object(forKey: Key.localUpdatedAt) as? Date ?? .distantPast
        if let remote = readRemote(), remote.updatedAt > localStamp {
            apply(remote)
        } else {
            push()
        }
    }

    // MARK: - Evicted iCloud items

    private var hasPendingDownload: Bool {
        let fm = FileManager.default
        return !fm.fileExists(atPath: fileURL.path)
            && fm.fileExists(atPath: placeholderURL.path)
    }

    /// Returns true when the snapshot is still only a cloud placeholder.
    @discardableResult
    private func triggerDownloadIfNeeded() -> Bool {
        guard hasPendingDownload else { return false }
        awaitingDownload = true
        let fm = FileManager.default
        // On a real ubiquitous item either URL starts the download. On a
        // plain local folder both calls fail harmlessly; the detection and
        // the write lock above are what the sync probe asserts.
        do { try fm.startDownloadingUbiquitousItem(at: fileURL) }
        catch { try? fm.startDownloadingUbiquitousItem(at: placeholderURL) }
        refreshFolderDescription()
        status = "正在从 iCloud 下载布局…完成后自动采用，期间不会覆盖云端"
        return true
    }

    // MARK: - Local change → push

    /// Hook called from `LauncherModel.persist()`. Kept deliberately cheap:
    /// the actual cloud write is debounced, and skipped entirely while a
    /// remote snapshot is being applied or sync is off.
    func localLayoutChanged() {
        guard isEnabled, !applyingRemote, model != nil else { return }
        defaults.set(Date(), forKey: Key.localUpdatedAt)
        // Hold writes until the cloud copy has landed; checkRemote() replays
        // this stamp through reconcileOnLaunch() once the download finishes.
        guard !awaitingDownload else { return }
        pushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.push() }
        pushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// `force` is the explicit "use this Mac's layout" action in Settings.
    func pushNow(force: Bool = false) {
        guard isEnabled else { return }
        if awaitingDownload && !force {
            status = "正在从 iCloud 下载布局，请稍候再上传"
            return
        }
        if force { awaitingDownload = false }
        pushWork?.cancel()
        push()
    }

    private func push() {
        guard isEnabled, let model else { return }
        do {
            try FileManager.default.createDirectory(at: folderURL,
                                                    withIntermediateDirectories: true)
            let now = Date()
            let layout = SyncedLayout(version: 1,
                                      updatedAt: now,
                                      deviceName: deviceName,
                                      pages: model.pages,
                                      hidden: model.hiddenTiles,
                                      manualHidden: Array(model.manualHidden).sorted(),
                                      pinned: Array(model.pinned).sorted())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(layout)
            try coordinatedWrite(data)
            defaults.set(now, forKey: Key.localUpdatedAt)
            lastSeenModification = modificationDate()
            pendingPushRetry = false
            refreshFolderDescription()
            status = "\(uploadedVerb) · \(timeString(now))"
        } catch {
            pendingPushRetry = true
            status = "上传失败：\(error.localizedDescription)（会自动重试）"
        }
    }

    /// NSFileCoordinator is mandatory for iCloud Drive files. `.forReplacing`
    /// hands us a temporary URL and performs the atomic swap, which prevents
    /// the conflict copies produced by an uncoordinated `Data.write(to:)`.
    private func coordinatedWrite(_ data: Data) throws {
        var coordinationError: NSError?
        var writeError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: fileURL, options: .forReplacing,
                               error: &coordinationError) { url in
            do { try data.write(to: url, options: .atomic) }
            catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    private func coordinatedRead() -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        var data: Data?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: fileURL,
                                                         options: [],
                                                         error: &coordinationError) { url in
            data = try? Data(contentsOf: url)
        }
        guard coordinationError == nil else { return nil }
        return data
    }

    // MARK: - Remote change → pull

    func pullNow() {
        guard isEnabled else { return }
        if triggerDownloadIfNeeded() { return }
        guard let remote = readRemote() else {
            status = "没有找到同步文件"
            return
        }
        apply(remote)
    }

    private func readRemote() -> SyncedLayout? {
        guard let data = coordinatedRead() else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SyncedLayout.self, from: data)
    }

    private func modificationDate() -> Date? {
        try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func apply(_ remote: SyncedLayout) {
        guard let model else { return }
        applyingRemote = true
        model.applySyncedLayout(remote)
        defaults.set(remote.updatedAt, forKey: Key.localUpdatedAt)
        defaults.set(Date(), forKey: Key.lastPull)
        lastSeenModification = modificationDate()
        status = "已接收 \(remote.deviceName) 的布局 · \(timeString(remote.updatedAt))"
        // applySyncedLayout() rescans apps asynchronously and ends in persist().
        // Keep the write suppressed until that has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.applyingRemote = false
        }
    }

    // MARK: - Diagnostic surface (--icloud-sync-probe / --layout-probe)

    func probeRead() -> SyncedLayout? { readRemote() }

    func probeDiagnostics() -> (cloudFolder: Bool, ready: Bool, badge: String,
                                awaiting: Bool, placeholder: Bool, fileExists: Bool) {
        (isICloudFolder, iCloudDriveReady, iCloudBadge, awaitingDownload,
         hasPendingDownload, FileManager.default.fileExists(atPath: fileURL.path))
    }

    /// Badge the default (real iCloud Drive) folder would show, without
    /// changing any state. Lets the probe assert iCloud detection while all
    /// file I/O stays in the isolated LAUNCHOS_SYNC_DIR.
    func probeDefaultFolderBadge() -> (path: String, ready: Bool, badge: String) {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs",
                                    isDirectory: true)
        let path = root.appendingPathComponent("LaunchOS", isDirectory: true).path
        return ((path as NSString).abbreviatingWithTildeInPath,
                iCloudDriveReady,
                badge(forCloudFolder: true, ready: iCloudDriveReady))
    }

    func probeReconcile() { reconcileOnLaunch() }

    // MARK: - Folder picker

    /// Single source of truth for the picker. Both the real Settings action
    /// and --sync-folder-probe go through here, so the probe measures the
    /// exact same prepare() path instead of a look-alike panel.
    private func makePreparedFolderPanel() -> NSOpenPanel {
        let panel = FilePanels.makeSyncFolderPanel()
        FilePanels.prepare(panel)
        return panel
    }

    func chooseFolder() {
        let panel = makePreparedFolderPanel()
        // MUST be the non-modal `begin(...)`: measured 2026-11-09 with
        // --picker-path-probe, `runModal()` resets the panel to level 8 while
        // the launcher window is 19 and the menu-bar cover is 26. The picker
        // was key but buried behind our own windows, so the button looked
        // dead. begin() keeps the level-27 armed panel and does not block the
        // main thread, letting the pending activate() settle.
        panel.begin { [weak self] response in
            // prepare() raises activeCount; release it on every exit,
            // including a cancelled picker. Without this, quitOnHide stays
            // suppressed forever.
            FilePanels.release()
            guard response == .OK, let url = panel.url, let self else { return }
            self.defaults.set(url.path, forKey: Key.folderPath)
            self.lastSeenModification = nil
            self.awaitingDownload = false
            self.refreshFolderDescription()
            if self.isEnabled { self.reconcileOnLaunch() }
        }
    }

    /// "在访达中显示同步文件夹": the path in the settings pane is plain text,
    /// so give the user a real way to open the folder (or select the snapshot).
    func revealInFinder() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: folderURL.path) {
            try? fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        }
        let target = fm.fileExists(atPath: fileURL.path) ? fileURL : folderURL
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    // MARK: - Diagnostic surface (--sync-folder-probe)

    func probeMakeFolderPanel() -> NSOpenPanel { makePreparedFolderPanel() }

    func useDefaultFolder() {
        defaults.removeObject(forKey: Key.folderPath)
        lastSeenModification = nil
        awaitingDownload = false
        refreshFolderDescription()
        if isEnabled { reconcileOnLaunch() }
    }
}
