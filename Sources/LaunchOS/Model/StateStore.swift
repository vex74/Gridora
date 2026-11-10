import Foundation

enum StateStore {

    static var directory: URL {
        // Diagnostic override for --layout-probe: HOME cannot isolate
        // NSHomeDirectory() on macOS, so probes need an explicit directory.
        if let override = ProcessInfo.processInfo.environment["LAUNCHOS_STATE_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        // Keep our state separate from any other launcher that happens to be
        // called "LaunchOS" (there is a shipping app with that name).
        return base.appendingPathComponent("com.vex.launchos", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("state.json") }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func load() -> PersistedState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(PersistedState.self, from: data)
    }

    static func save(_ state: PersistedState) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Gridora: failed to save state — \(error)")
        }
    }
}
