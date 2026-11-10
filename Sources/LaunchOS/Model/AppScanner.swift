import AppKit
import Foundation

enum AppScanner {

    static let searchRoots: [String] = {
        var roots = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications"
        ]
        // /Applications sub-folders that hold useful apps
        for extra in ["/Applications/Utilities"] {
            if FileManager.default.fileExists(atPath: extra) { roots.append(extra) }
        }
        return roots
    }()

    /// User-defined folders set from the settings panel (应用位置).
    static var extraFolders: [String] = []

    static var allRoots: [String] {
        searchRoots + extraFolders.filter { FileManager.default.fileExists(atPath: $0) }
    }

    static func scan() -> [AppInfo] {
        var seen = Set<String>()
        var result: [AppInfo] = []

        for root in allRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension == "app" else { continue }
                enumerator.skipDescendants()
                guard let info = makeAppInfo(at: url), !seen.contains(info.bundleID) else { continue }
                seen.insert(info.bundleID)
                result.append(info)
            }
        }

        result.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return result
    }

    private static func makeAppInfo(at url: URL) -> AppInfo? {
        guard let bundle = Bundle(url: url), let info = bundle.infoDictionary else { return nil }

        if (info["LSUIElement"] as? Bool) == true { return nil }
        if (info["LSBackgroundOnly"] as? Bool) == true { return nil }

        let bundleID = (info["CFBundleIdentifier"] as? String) ?? url.path
        if bundleID.hasPrefix("com.apple.WebKit") { return nil }

        // `infoDictionary` is the *raw* Info.plist. System apps and most
        // Chinese third-party apps keep their Chinese label in
        // zh-Hans.lproj/InfoPlist.strings, so the raw value is English
        // ("Calculator", "Qianwen", "WeChat"). Finder reads the localised
        // value. Collect every candidate, prefer a Chinese one, and keep the
        // rest as search aliases so both languages stay searchable.
        let fileName = url.deletingPathExtension().lastPathComponent
        let raw = [
            bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            FileManager.default.displayName(atPath: url.path),
            info["CFBundleDisplayName"] as? String,
            bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
            info["CFBundleName"] as? String,
            bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String,
            bundle.localizedInfoDictionary?["CFBundleName"] as? String,
            fileName
        ]

        var seen = Set<String>()
        var candidates: [String] = []
        for value in raw {
            guard let cleaned = cleanName(value),
                  seen.insert(cleaned.lowercased()).inserted else { continue }
            candidates.append(cleaned)
        }
        guard let name = candidates.first(where: containsCJK) ?? candidates.first else { return nil }

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 256, height: 256)

        let primary = romanize(name)
        // Only human-readable name candidates belong in the alias index. A
        // bundle-id tail is often an opaque PWA hash (Chrome app shortcuts
        // use com.google.Chrome.app.<hash>), which made "gg" and "chrome"
        // surface a GitHub shortcut ahead of the real matches.
        let aliases = candidates.map { $0.lowercased() }

        var romanized = Set<String>()
        var initials = Set<String>()
        for candidate in candidates {
            let r = romanize(candidate)
            if !r.full.isEmpty { romanized.insert(r.full) }
            if !r.initials.isEmpty { initials.insert(r.initials) }
        }

        return AppInfo(bundleID: bundleID,
                       name: name,
                       path: url.path,
                       pinyin: primary.full,
                       pinyinInitials: primary.initials,
                       aliases: aliases,
                       romanizedAliases: Array(romanized),
                       romanizedInitials: Array(initials),
                       icon: icon)
    }

    private static func cleanName(_ value: String?) -> String? {
        guard var s = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        if s.hasSuffix(".app") { s = String(s.dropLast(4)) }
        return s.isEmpty || s.hasPrefix("com.") ? nil : s
    }

    private static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x4E00...0x9FFF).contains(Int($0.value)) }
    }

    /// `.toLatin` turns 「安卓去广告」 into "an zhuo qu guang gao" (with tone
    /// marks and spaces). Keep a compact full form for "guanggao" and the
    /// syllable initials for "azqgg"; English names get the same treatment so
    /// "am" matches "Activity Monitor".
    private static func romanize(_ source: String) -> (full: String, initials: String) {
        let latin = source.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? source
        let parts = latin.lowercased()
            .split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
            .map(String.init)
            .filter { !$0.isEmpty }
        return (parts.joined(),
                parts.compactMap { $0.first.map(String.init) }.joined())
    }
}
