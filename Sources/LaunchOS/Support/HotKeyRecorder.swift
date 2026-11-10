import AppKit
import Carbon.HIToolbox
import Foundation

/// Captures one key-down while the Settings pane is open. The AppDelegate key
/// monitor yields every event while `isRecording` is true, so the recorder is
/// the single consumer and no launcher action fires mid-recording.
///
/// `validate` is supplied by the caller (`HotKeyRules.rejection`), which is
/// the single source of truth for bare-key / modifier / collision rules. The
/// recorder deliberately knows nothing about which role is being recorded,
/// so Settings, the probe and the recorder can never disagree.
enum HotKeyRecorder {
    static private(set) var isRecording = false
    private static var monitor: Any?

    /// `completion` receives the captured combo (nil = cancelled / rejected)
    /// plus a user-readable message. The caller keeps the old shortcut on nil.
    static func begin(validate: @escaping (KeyChord) -> String?,
                      completion: @escaping (KeyChord?, String) -> Void) {
        cancel()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                if event.keyCode == UInt32(kVK_Escape) {
                    finish()
                    completion(nil, "已取消，快捷键保持不变")
                    return
                }
                let combo = KeyChord.from(event)
                if let reason = validate(combo) {
                    finish()
                    completion(nil, reason)
                    return
                }
                finish()
                completion(combo, "已设为 \(combo.label)，立即生效")
            }
            return nil
        }
    }

    static func cancel() { finish() }

    private static func finish() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}
