import AppKit
import Foundation

/// Result of looking for a usable desktop picture. `status` is shown verbatim
/// in the appearance settings pane so a failure is visible instead of silently
/// flipping the switch back off.
struct WallpaperResolution {
    let image: NSImage?
    let status: String
}

/// Resolves the current desktop picture across the two wallpaper systems that
/// coexist on macOS 14/15.
///
/// The old implementation called `NSWorkspace.desktopImageURL(for:)` and fed
/// the result straight into `NSImage(contentsOf:)`. On macOS Sequoia, when the
/// wallpaper is an **image folder** (System Settings > Wallpaper > "folder"),
/// that API returns a directory — on this machine `~/Desktop` rather than
/// `~/Desktop/壁纸/` — so decoding always failed and the caller reset
/// `settings.useWallpaper` to false. The switch appeared impossible to turn on.
///
/// Resolution order:
/// 1. A user-picked file/folder (NSOpenPanel, persisted path).
/// 2. `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`,
///    where Sonoma+ records the real image / imageFolder URL.
/// 3. `NSWorkspace.desktopImageURL(for:)`, including a shallow walk of the
///    returned directory (covers systems where the Store format changes).
///
/// Nothing here mutates settings. If every candidate fails, the caller keeps
/// the switch on and `BackgroundView` falls back to the procedural backdrop.
enum WallpaperResolver {

    private static let imageExtensions: Set<String> =
        ["heic", "heif", "jpg", "jpeg", "png", "tiff", "tif", "webp", "gif", "bmp"]

    /// NSImage decodes these reliably; webp/gif are tried after the common ones.
    private static let preferredExtensions =
        ["heic", "heif", "jpg", "jpeg", "png", "tiff", "tif", "webp", "gif", "bmp"]

    /// Guard against decoding the whole folder when it contains hundreds of
    /// multi-megabyte images.
    private static let maxCandidates = 24

    static func resolve(customPath: String?, screen: NSScreen?) -> WallpaperResolution {
        if let customPath, !customPath.isEmpty {
            let url = URL(fileURLWithPath: customPath)
            // A user-picked folder often contains another folder (e.g. a
            // "壁纸" subfolder), so search two levels deep just like the
            // system-wallpaper fallback below. Depth 1 made such a choice
            // look like "the wallpaper did not change".
            if let found = loadCandidate(url, depth: 2) {
                return WallpaperResolution(image: found.0,
                                           status: "自定义图片 · \(found.1.lastPathComponent)")
            }
            return WallpaperResolution(image: nil,
                                       status: "自定义路径无法读取（需为图片或含图片的文件夹）：\(url.lastPathComponent)")
        }

        for url in wallpaperStoreURLs() {
            if let found = loadCandidate(url) {
                return WallpaperResolution(image: found.0,
                                           status: "系统壁纸 · \(found.1.lastPathComponent)")
            }
        }

        if let screen, let url = NSWorkspace.shared.desktopImageURL(for: screen) {
            // A directory here is expected for image-folder wallpapers; walk
            // one level down so ~/Desktop → ~/Desktop/壁纸/ still resolves.
            if let found = loadCandidate(url, depth: 2) {
                return WallpaperResolution(image: found.0,
                                           status: "系统壁纸 · \(found.1.lastPathComponent)")
            }
        }

        return WallpaperResolution(image: nil,
                                   status: "未找到可用的桌面壁纸，可点下方「选择图片」指定")
    }

    // MARK: - Loading

    /// Returns the decoded image plus the exact file it came from. A directory
    /// is searched for the first decodable image, optionally one level deep.
    private static func loadCandidate(_ url: URL, depth: Int = 1) -> (NSImage, URL)? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }

        if !isDir.boolValue {
            guard imageExtensions.contains(url.pathExtension.lowercased()),
                  let image = loadImage(url) else { return nil }
            return (image, url)
        }

        let ordered = orderedImageURLs(in: url, depth: depth)
        for candidate in ordered.prefix(maxCandidates) {
            if let image = loadImage(candidate) { return (image, candidate) }
        }
        return nil
    }

    private static func loadImage(_ url: URL) -> NSImage? {
        if let image = NSImage(contentsOf: url) { return image }
        // Some HEIC/WEBP variants decode only from raw data.
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }

    private static func orderedImageURLs(in directory: URL, depth: Int) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }

        var files: [URL] = []
        var folders: [URL] = []
        for entry in entries {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: entry.path, isDirectory: &isDir)
            if isDir.boolValue {
                if depth > 1 { folders.append(entry) }
            } else if imageExtensions.contains(entry.pathExtension.lowercased()) {
                files.append(entry)
            }
        }

        let rank: (URL) -> Int = { url in
            preferredExtensions.firstIndex(of: url.pathExtension.lowercased())
                ?? preferredExtensions.count
        }
        files.sort { lhs, rhs in
            let l = rank(lhs), r = rank(rhs)
            return l == r ? lhs.lastPathComponent < rhs.lastPathComponent : l < r
        }

        var result = files
        if depth > 1 {
            for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                result.append(contentsOf: orderedImageURLs(in: folder, depth: depth - 1))
                if result.count >= maxCandidates { break }
            }
        }
        return result
    }

    // MARK: - macOS Sonoma+ Wallpaper Store

    /// Reads `Index.plist` and extracts the image / imageFolder URLs recorded
    /// for "All spaces and displays" and each individual display. The
    /// `Configuration` field is an embedded binary plist.
    private static func wallpaperStoreURLs() -> [URL] {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let index = base
            .appendingPathComponent("com.apple.wallpaper", isDirectory: true)
            .appendingPathComponent("Store", isDirectory: true)
            .appendingPathComponent("Index.plist")

        guard let root = NSDictionary(contentsOf: index) as? [String: Any] else { return [] }

        var rawChoices: [[String: Any]] = []
        if let all = root["AllSpacesAndDisplays"] as? [String: Any],
           let desktop = all["Desktop"] as? [String: Any] {
            rawChoices.append(contentsOf: choices(in: desktop))
        }
        if let displays = root["Displays"] as? [String: Any] {
            for value in displays.values {
                guard let display = value as? [String: Any],
                      let desktop = display["Desktop"] as? [String: Any] else { continue }
                rawChoices.append(contentsOf: choices(in: desktop))
            }
        }

        var urls: [URL] = []
        var seen = Set<String>()
        for choice in rawChoices {
            guard let config = choice["Configuration"] as? Data,
                  let plist = try? PropertyListSerialization.propertyList(from: config,
                                                                          options: [],
                                                                          format: nil),
                  let dict = plist as? [String: Any],
                  let url = urlFromConfiguration(dict) else { continue }
            if seen.insert(url.path).inserted { urls.append(url) }
        }
        return urls
    }

    private static func choices(in desktop: [String: Any]) -> [[String: Any]] {
        guard let content = desktop["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]] else { return [] }
        return choices
    }

    private static func urlFromConfiguration(_ dict: [String: Any]) -> URL? {
        let raw: String?
        if let container = dict["url"] as? [String: Any] {
            raw = container["relative"] as? String
        } else {
            raw = dict["url"] as? String
        }
        guard let raw, !raw.isEmpty else { return nil }
        if let url = URL(string: raw), url.scheme != nil { return url }
        return URL(fileURLWithPath: raw)
    }
}
