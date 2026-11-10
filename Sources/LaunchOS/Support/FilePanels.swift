import AppKit
import UniformTypeIdentifiers

/// Every file picker in LaunchOS must go through here.
///
/// Why: the launcher owns two always-on-top windows — the main window at
/// `level = 19` and the click-through menu-bar cover at
/// `statusWindow + 1` (26 on this Mac). A stock `NSOpenPanel` / `NSSavePanel`
/// is a **modeless level-0 window** (`beginWithCompletionHandler:` is not a
/// sheet). Measured 2026-11-06 with the real SDK:
///
///     main=19 cover=26 panelLevel=0 panelVisible=true panelKey=false
///     nsappActive=false  panelAboveMain=false panelAboveCover=false
///
/// so the picker is displayed but completely buried behind the launcher:
/// no clicks, no keyboard, and the user reads it as "the button does nothing".
/// Lifting it to `statusWindow + 2` and activating the .accessory app gives
/// `panelKey=true / nsappActive=true / above both windows`.
///
/// The second half of the fix is the guard: the picker is served by an XPC
/// process and is modeless, so clicking away to find an image is normal.
/// Without `isPicking`, `applicationDidResignActive` hides the launcher and
/// `quitOnHide` terminates the process — taking the picker with it.
enum FilePanels {

    /// Above the menu-bar cover (statusWindow + 1), below nothing we own.
    static let panelLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)

    /// Main-actor only in practice (AppKit callbacks and SwiftUI actions).
    /// `nonisolated(unsafe)` keeps the guard readable from the delegate's
    /// resignation handler without forcing a Swift 6 actor hop on a hot path.
    nonisolated(unsafe) private static var activeCount = 0

    /// True while a file panel is on screen. Read by `AppDelegate` to suppress
    /// focus-loss auto-hide and quit-on-hide.
    static var isPicking: Bool { activeCount > 0 }

    /// Configures and arms one panel. Call immediately before `begin(...)` or
    /// `runModal()`; pair it with `release()` in the completion handler.
    static func prepare(_ panel: NSSavePanel) {
        panel.level = panelLevel
        activeCount += 1
        // An .accessory app does not get a Dock tile; without this the picker
        // is visible but never becomes key (measured panelKey=false).
        NSApp.activate(ignoringOtherApps: true)
    }

    static func release() {
        activeCount = max(0, activeCount - 1)
    }

    /// The wallpaper chooser. `allowedContentTypes` deliberately stays loose:
    /// abstract `.image` / `.folder` used to grey out HEIC variants and some
    /// wallpaper folders. `WallpaperResolver` validates the extension after the
    /// choice and reports the reason in the appearance pane instead.
    /// The layout-sync folder chooser. It lives here rather than inline in
    /// LayoutSync so the sync pane cannot skip prepare()/release() again:
    /// without the level + activation + isPicking guard, the picker is buried
    /// behind the launcher and quitOnHide kills the process mid-selection.
    static func makeSyncFolderPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择用于同步图标布局的文件夹，建议放在 iCloud Drive 或其他云盘目录"
        return panel
    }

    static func makeWallpaperPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "选择壁纸图片或壁纸文件夹"
        panel.message = "系统壁纸设为「图片文件夹」时会自动取其中一张；也可以直接指定一张图片。"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel
    }
}
