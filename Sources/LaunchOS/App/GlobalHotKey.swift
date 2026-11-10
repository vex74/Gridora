import Carbon.HIToolbox
import Foundation

/// Registers the system-wide launcher shortcut. The combination is no longer
/// hard-wired: `AppDelegate.applyLauncherHotKey()` re-registers it whenever
/// Settings changes, so a recorded chord takes effect without a restart.
///
/// While the launcher chord is still the shipped ⌃⌥Space, the two legacy spare
/// chords (⌃⌥L / F4) are registered too; a custom chord replaces all three.
final class GlobalHotKey {

    static let shared = GlobalHotKey()

    var handler: (() -> Void)?

    /// The exact combos handed to Carbon on the last registration. Read by
    /// `--launcher-hotkey-probe` so it can assert the real entry point rather
    /// than a look-alike helper.
    private(set) var registeredCombos: [KeyChord] = []
    private(set) var lastStatus: OSStatus = noErr
    private(set) var activeRegistrationCount = 0

    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var eventHandler: EventHandlerRef?
    private var installed = false

    private init() {}

    func register(_ combos: [KeyChord]) {
        installHandlerIfNeeded()
        unregisterAll()
        registeredCombos = combos
        lastStatus = noErr

        for (index, combo) in combos.enumerated() {
            let hotKeyID = EventHotKeyID(signature: OSType(0x4C4F5321), id: UInt32(index + 1))
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID,
                                             GetApplicationEventTarget(), 0, &ref)
            lastStatus = status
            hotKeyRefs.append(status == noErr ? ref : nil)
            if status != noErr {
                // A system feature may already own F3 / F4; the Settings pane
                // surfaces this through a toast instead of silently keeping
                // the old chord.
                NSLog("Gridora: hotkey \(combo.label) unavailable (status \(status))")
            }
        }
        activeRegistrationCount = hotKeyRefs.filter { $0 != nil }.count
    }

    /// True when at least one chord could be claimed (another launcher may
    /// already own the chosen combination).
    var hasAnyHotKey: Bool { activeRegistrationCount > 0 }
    var lastRegistrationFailed: Bool { activeRegistrationCount < registeredCombos.count }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            GlobalHotKey.shared.fire()
            return noErr
        }, 1, &eventType, nil, &eventHandler)
    }

    private func unregisterAll() {
        for ref in hotKeyRefs.compactMap({ $0 }) { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
        activeRegistrationCount = 0
    }

    fileprivate func fire() {
        DispatchQueue.main.async { [weak self] in
            self?.handler?()
        }
    }
}
