import Foundation

/// Single source of truth for the *user-facing* product name.
///
/// Only the display name is rebranded. The bundle file name, executable,
/// identifier, Swift module, state directory, log prefix, UserDefaults keys
/// and iCloud snapshot name intentionally stay "LaunchOS": renaming any of
/// them would orphan the Dock pin, the real `state.json` and the existing
/// cloud snapshot. Finder/Dock read CFBundleDisplayName from Info.plist, so
/// the desktop icon can be labelled Gridora while its path is unchanged.
///
/// Every visible string goes through this enum so a future rename is a
/// one-file Info.plist edit, never a project-wide search-and-replace.
enum AppBrand {
    /// Used only when the bundle has no name keys (e.g. a bare unit test host).
    static let fallbackName = "Gridora"

    static var displayName: String {
        let info = Bundle.main.infoDictionary
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = info?[key] as? String, !name.isEmpty { return name }
        }
        return fallbackName
    }

    static var quitTitle: String { "退出 \(displayName)" }
    static var aboutFooter: String { "\(displayName) · 原生 macOS 启动台" }
    static var statusItemDescription: String { displayName }

    /// The cloud snapshot file itself is a persisted technical name -- it is
    /// deliberately NOT derived from displayName, otherwise the existing
    /// iCloud Drive file would be abandoned on the next launch.
    static let syncFileName = "LaunchOS-layout.json"

    static var restorePanelMessage: String {
        "可选择 \(displayName) 的布局备份文件，或同步功能生成的 \(syncFileName)。"
    }

    static var backupFilePrefix: String { "\(displayName)-布局-" }
}
