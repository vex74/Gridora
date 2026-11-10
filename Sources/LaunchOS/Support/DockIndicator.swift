import Foundation

/// The little "running" dot under a Dock icon is painted by the Dock process
/// itself. macOS does not expose a per-app switch for it — only a global one
/// (System Settings ▸ Desktop & Dock ▸ Show indicators for open applications).
/// We read and write that same preference and bounce the Dock so the change
/// takes effect immediately.
enum DockIndicator {
    private static let domain = "com.apple.dock"
    private static let key = "show-process-indicators"

    /// Missing key means "shown", which is the system default.
    static var isHidden: Bool {
        let value = UserDefaults(suiteName: domain)?.object(forKey: key) as? Bool
        return value == false
    }

    static func setHidden(_ hidden: Bool) {
        run("/usr/bin/defaults", ["write", domain, key, "-bool", hidden ? "false" : "true"])
        run("/usr/bin/killall", ["Dock"])
    }

    private static func run(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
