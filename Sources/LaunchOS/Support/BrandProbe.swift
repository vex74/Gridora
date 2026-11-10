import Foundation

/// Deterministic assertions for `LaunchOS --brand-probe`: the user-facing
/// name is Gridora everywhere it is visible, while every persisted technical
/// identifier still has its original "LaunchOS" value. Off by default, writes
/// /tmp/launchos-brand.log. Check F asserts the Finder/Dock-visible label,
/// which follows the bundle FILE name, not CFBundleDisplayName alone.
enum BrandProbe {
    static let logPath = "/tmp/launchos-brand.log"
    static let expectedName = "Gridora"
    static let legacyName = "LaunchOS"

    /// A visible product string must carry the new brand and never the old one.
    /// File *names* are checked separately because the iCloud snapshot name is
    /// deliberately still "LaunchOS-layout.json".
    static func visibleNameIsClean(_ text: String) -> Bool {
        text.contains(expectedName) && !text.contains(legacyName)
    }

    @discardableResult
    static func run() -> Bool {
        var lines: [String] = ["BRAND PROBE"]
        var all = true
        func check(_ tag: String, _ ok: Bool, _ detail: String) {
            lines.append("\(tag) \(ok ? "PASS" : "FAIL") \(detail)")
            if !ok { all = false }
        }

        let info = Bundle.main.infoDictionary ?? [:]
        let display = info["CFBundleDisplayName"] as? String
        let name = info["CFBundleName"] as? String
        let executable = info["CFBundleExecutable"] as? String
        let identifier = info["CFBundleIdentifier"] as? String
        let copyright = info["NSHumanReadableCopyright"] as? String ?? ""

        // A. Both name keys must agree, otherwise Finder and the in-app UI
        // could show different products. --appearance-probe style: prove the
        // detector rejects the legacy value first (E0 below).
        check("A display", display == expectedName && name == expectedName
              && AppBrand.displayName == expectedName
              && copyright.hasPrefix(expectedName) && !copyright.contains(legacyName),
              "display=\(display ?? "nil") name=\(name ?? "nil") brand=\(AppBrand.displayName) copyright=\(copyright)")

        // B. Rebranding must NOT orphan the Dock pin, the state directory or
        // the existing iCloud Drive snapshot.
        check("B identity", executable == "LaunchOS" && identifier == "com.vex.launchos"
              && AppBrand.syncFileName == "LaunchOS-layout.json",
              "exec=\(executable ?? "nil") id=\(identifier ?? "nil") sync=\(AppBrand.syncFileName)")

        // C. Every product-facing string comes from AppBrand.
        let visible = [AppBrand.quitTitle, AppBrand.aboutFooter, AppBrand.statusItemDescription]
        check("C strings", visible.allSatisfy(visibleNameIsClean),
              "quit=\(AppBrand.quitTitle) about=\(AppBrand.aboutFooter) status=\(AppBrand.statusItemDescription)")

        // D. The restore panel may mention the legacy *file name* (it is a
        // real file on disk) but its product wording and new backups are Gridora.
        let message = AppBrand.restorePanelMessage
        let backup = LayoutBackup.defaultFileName(Date(timeIntervalSince1970: 1_700_000_000))
        check("D files", message.hasPrefix("可选择 \(expectedName) 的布局备份文件")
              && message.contains(AppBrand.syncFileName)
              && backup.hasPrefix("\(expectedName)-布局-") && backup.hasSuffix(".json"),
              "message=\(message) backup=\(backup)")

        // E. Negative control: an always-true probe would be meaningless.
        check("E0 detector", !visibleNameIsClean("LaunchOS · 原生 macOS 启动台")
              && !visibleNameIsClean("退出 LaunchOS")
              && visibleNameIsClean("Gridora · 原生 macOS 启动台"),
              "legacy strings rejected, new string accepted")

        // F. Finder/Dock label follows the bundle FILE name. Measured with two
        // never-registered copies: Gridora.app -> "Gridora", LaunchOS.app ->
        // "LaunchOS" even with localized InfoPlist.strings present. This is
        // the name the user actually sees, so it is a hard assertion.
        let finderName = FileManager.default.displayName(atPath: Bundle.main.bundlePath)
        check("F finder", finderName == expectedName
              && Bundle.main.bundleURL.lastPathComponent == "\(expectedName).app",
              "displayName=\(finderName) bundle=\(Bundle.main.bundleURL.lastPathComponent)")
        lines.append(all ? "PASS" : "FAIL")
        lines.append("DONE")
        try? (lines.joined(separator: "\n") + "\n")
            .write(toFile: logPath, atomically: true, encoding: .utf8)
        return all
    }
}
