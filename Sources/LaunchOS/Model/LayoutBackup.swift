import AppKit
import Foundation

/// Errors surfaced in the settings pane. A failed read must never leave the
/// current arrangement half-mutated, so every throwing path happens before
/// `applySyncedLayout` is called.
enum LayoutBackupError: LocalizedError {
    case unsupportedVersion(Int)
    case unreadable(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "备份文件版本不受支持（v\(version)）"
        case .unreadable(let reason):
            return "无法读取布局：\(reason)"
        case .writeFailed(let reason):
            return "无法保存布局：\(reason)"
        }
    }
}

/// Manual, file-based layout backup/restore.
///
/// Deliberately shares the `SyncedLayout` envelope with `LayoutSync`: the two
/// files are interchangeable, and neither carries per-Mac preferences such as
/// columns/rows/icon size/wallpaper/usage. Restoring on another Mac therefore
/// changes only the arrangement, never that Mac's own settings.
///
/// Pure file/format logic only — no panels, no model dependency — so the
/// round trip can be exercised by `--layout-tools-probe`.
enum LayoutBackup {
    static let version = 1
    static let fileExtension = "json"
    static let maxFileSize = 8 * 1024 * 1024

    private static var deviceName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    static func defaultFileName(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "\(AppBrand.backupFilePrefix)\(formatter.string(from: date)).\(fileExtension)"
    }

    static func snapshot(pages: [[Tile]],
                         hidden: [Tile],
                         manualHidden: Set<String>,
                         pinned: Set<String>,
                         date: Date = Date()) -> SyncedLayout {
        SyncedLayout(version: version,
                     updatedAt: date,
                     deviceName: deviceName,
                     pages: pages,
                     hidden: hidden,
                     manualHidden: manualHidden.sorted(),
                     pinned: pinned.sorted())
    }

    static func encode(_ layout: SyncedLayout) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(layout)
    }

    /// Strict on purpose: a truncated or foreign JSON file is rejected before
    /// it can touch the live arrangement.
    static func decode(_ data: Data) throws -> SyncedLayout {
        guard data.count <= maxFileSize else {
            throw LayoutBackupError.unreadable("文件过大（超过 8 MB）")
        }
        let layout: SyncedLayout
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            layout = try decoder.decode(SyncedLayout.self, from: data)
        } catch {
            throw LayoutBackupError.unreadable(error.localizedDescription)
        }
        guard layout.version == version else {
            throw LayoutBackupError.unsupportedVersion(layout.version)
        }
        return layout
    }

    static func write(_ layout: SyncedLayout, to url: URL) throws {
        do {
            try encode(layout).write(to: url, options: .atomic)
        } catch {
            throw LayoutBackupError.writeFailed(error.localizedDescription)
        }
    }

    static func read(from url: URL) throws -> SyncedLayout {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LayoutBackupError.unreadable(error.localizedDescription)
        }
        return try decode(data)
    }
}
