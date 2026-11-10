import AppKit
import Carbon.HIToolbox
import Foundation

/// A persisted, user-recordable shortcut. Carbon virtual key codes are used
/// for both the system-wide `RegisterEventHotKey` registration and the local
/// key monitor, so one value works in both places and survives keyboard
/// layout changes. `label` is captured from the live event (not recomputed)
/// because non-ANSI layouts cannot be reconstructed from a key code alone.
struct KeyChord: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier bits: cmdKey / controlKey / optionKey / shiftKey.
    var modifiers: UInt32
    var label: String

    /// Legacy name: the search chord was the first recordable shortcut.
    static let `default` = defaultSearch

    static let defaultSearch = KeyChord(keyCode: UInt32(kVK_ANSI_F),
                                        modifiers: UInt32(cmdKey), label: "⌘F")
    static let defaultLauncher = KeyChord(keyCode: UInt32(kVK_Space),
                                          modifiers: UInt32(controlKey | optionKey),
                                          label: "⌃⌥Space")
    static let defaultPreviousPage = KeyChord(keyCode: UInt32(kVK_LeftArrow),
                                              modifiers: UInt32(cmdKey), label: "⌘←")
    static let defaultNextPage = KeyChord(keyCode: UInt32(kVK_RightArrow),
                                          modifiers: UInt32(cmdKey), label: "⌘→")

    /// Older builds registered these two extra launcher chords unconditionally.
    /// They stay active while the launcher chord is still the shipped default,
    /// so an upgraded state.json behaves exactly as before. As soon as the
    /// user records a custom launcher chord they are released.
    static let legacyAlternates: [KeyChord] = [
        KeyChord(keyCode: UInt32(kVK_ANSI_L),
                 modifiers: UInt32(controlKey | optionKey), label: "⌃⌥L"),
        KeyChord(keyCode: UInt32(kVK_F4), modifiers: 0, label: "F4")
    ]

    static let alternateSearch = KeyChord(keyCode: UInt32(kVK_ANSI_F),
                                          modifiers: UInt32(optionKey), label: "⌥F")
    static let alternatePreviousPage = KeyChord(keyCode: UInt32(kVK_LeftArrow),
                                                 modifiers: UInt32(optionKey), label: "⌥←")
    static let alternateNextPage = KeyChord(keyCode: UInt32(kVK_RightArrow),
                                            modifiers: UInt32(optionKey), label: "⌥→")

    /// Bare function keys (F3 in BuhoLaunchpad). The launcher role may also
    /// accept *any* single key; the other roles stay modifier-only because a
    /// bare key would collide with typing and grid navigation inside the app.
    static let functionKeys: [UInt32: String] = [
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15"
    ]

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        let f = flags.intersection(.deviceIndependentFlagsMask)
        var value: UInt32 = 0
        if f.contains(.command) { value |= UInt32(cmdKey) }
        if f.contains(.control) { value |= UInt32(controlKey) }
        if f.contains(.option) { value |= UInt32(optionKey) }
        if f.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }

    static func makeLabel(_ event: NSEvent) -> String {
        let m = carbonModifiers(event.modifierFlags)
        var prefix = ""
        if m & UInt32(controlKey) != 0 { prefix += "⌃" }
        if m & UInt32(optionKey) != 0 { prefix += "⌥" }
        if m & UInt32(shiftKey) != 0 { prefix += "⇧" }
        if m & UInt32(cmdKey) != 0 { prefix += "⌘" }

        let code = UInt32(event.keyCode)
        if let name = functionKeys[code] { return prefix + name }
        let key: String
        switch code {
        case UInt32(kVK_Space): key = "Space"
        case UInt32(kVK_Return): key = "↩"
        case UInt32(kVK_Tab): key = "⇥"
        case UInt32(kVK_Delete): key = "⌫"
        case UInt32(kVK_ForwardDelete): key = "⌦"
        case UInt32(kVK_LeftArrow): key = "←"
        case UInt32(kVK_RightArrow): key = "→"
        case UInt32(kVK_UpArrow): key = "↑"
        case UInt32(kVK_DownArrow): key = "↓"
        case UInt32(kVK_Home): key = "↖"
        case UInt32(kVK_End): key = "↘"
        case UInt32(kVK_PageUp): key = "⇞"
        case UInt32(kVK_PageDown): key = "⇟"
        case UInt32(kVK_Escape): key = "Esc"
        default:
            let raw = (event.charactersIgnoringModifiers ?? "").uppercased()
            // Function keys report private-use Unicode (U+F700…U+F8FF) as
            // their "characters"; never show that glyph in Settings.
            let printable = raw.unicodeScalars.allSatisfy { $0.value < 0xF700 || $0.value > 0xF8FF }
            key = raw.isEmpty || !printable ? "键\(code)" : raw
        }
        return prefix + key
    }

    static func from(_ event: NSEvent) -> KeyChord {
        KeyChord(keyCode: UInt32(event.keyCode),
                 modifiers: carbonModifiers(event.modifierFlags),
                 label: makeLabel(event))
    }

    func matches(_ event: NSEvent) -> Bool {
        UInt32(event.keyCode) == keyCode
            && KeyChord.carbonModifiers(event.modifierFlags) == modifiers
    }

    /// Two chords collide when they trigger on the same physical key with the
    /// same modifiers, even if their captured labels differ.
    func hasSameCombo(as other: KeyChord) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }

    var hasModifiers: Bool { modifiers != 0 }
    var isBareFunctionKey: Bool {
        modifiers == 0 && KeyChord.functionKeys[keyCode] != nil
    }

    /// Virtual key codes that are modifiers themselves. A key-down event never
    /// carries one of these, but a hand-edited state.json could; registering
    /// one globally would make the keyboard unusable.
    static let bareModifierKeyCodes: Set<UInt32> = [
        UInt32(kVK_Command), UInt32(kVK_Shift), UInt32(kVK_CapsLock),
        UInt32(kVK_Option), UInt32(kVK_Control), UInt32(kVK_RightShift),
        UInt32(kVK_RightOption), UInt32(kVK_RightControl), UInt32(kVK_Function)
    ]

    /// macOS virtual key codes live in 0…0x7F. Anything outside that range is
    /// a corrupt state value, not a key the user could have pressed.
    var hasPlausibleKeyCode: Bool {
        keyCode <= 0x7F && !KeyChord.bareModifierKeyCodes.contains(keyCode)
    }

    /// `allowsBareKeys` is for the launcher only: one key, no modifiers.
    /// `allowsBareFunctionKeys` keeps the older F1–F15 allowance for the
    /// in-app roles. Search allows neither.
    func isValid(allowsBareKeys: Bool = false,
                 allowsBareFunctionKeys: Bool = false) -> Bool {
        guard hasPlausibleKeyCode,
              keyCode != UInt32(kVK_Escape),
              !label.isEmpty else { return false }
        if hasModifiers { return true }
        if allowsBareKeys { return true }
        return allowsBareFunctionKeys && isBareFunctionKey
    }

    /// Kept for the older search-hotkey probe: no bare keys of any kind.
    var isValid: Bool { isValid() }

    var conflictsWithLauncherChord: Bool {
        hasSameCombo(as: .defaultLauncher)
            || KeyChord.legacyAlternates.contains { hasSameCombo(as: $0) }
    }
}

// MARK: - Roles & rules

/// The four recordable shortcuts. `chord(in:)` / `set(_:in:)` are the only
/// places that map a role onto a Settings field, so Settings, the recorder,
/// the UI and the probes cannot disagree about which field a role owns.
enum HotKeyRole: String, CaseIterable, Identifiable {
    case launcher
    case previousPage
    case nextPage
    case search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .launcher: return "显示启动台"
        case .previousPage: return "前一页"
        case .nextPage: return "后一页"
        case .search: return "打开搜索"
        }
    }

    var defaultChord: KeyChord {
        switch self {
        case .launcher: return .defaultLauncher
        case .previousPage: return .defaultPreviousPage
        case .nextPage: return .defaultNextPage
        case .search: return .defaultSearch
        }
    }

    var alternateChord: KeyChord {
        switch self {
        case .launcher: return KeyChord(keyCode: UInt32(kVK_F3), modifiers: 0, label: "F3")
        case .previousPage: return .alternatePreviousPage
        case .nextPage: return .alternateNextPage
        case .search: return .alternateSearch
        }
    }

    /// Only the system-wide launcher may be a completely bare key. The three
    /// in-app roles must keep a modifier, otherwise they would fire while the
    /// user types in the search field or navigates the icon grid.
    var allowsBareKeys: Bool { self == .launcher }

    var allowsBareFunctionKeys: Bool { self != .search }

    func chord(in settings: Settings) -> KeyChord {
        switch self {
        case .launcher: return settings.launcherHotKey
        case .previousPage: return settings.previousPageHotKey
        case .nextPage: return settings.nextPageHotKey
        case .search: return settings.searchHotKey
        }
    }

    func set(_ chord: KeyChord, in settings: inout Settings) {
        switch self {
        case .launcher: settings.launcherHotKey = chord
        case .previousPage: settings.previousPageHotKey = chord
        case .nextPage: settings.nextPageHotKey = chord
        case .search: settings.searchHotKey = chord
        }
    }
}

enum HotKeyRules {
    /// AppKit menus and the launcher's own command-key defaults own these.
    /// Letting a global Carbon hot key claim ⌘Q / ⌘Tab / ⌘Space would make
    /// the app (or the whole Mac) unusable, so recording rejects them.
    static let systemReserved: [KeyChord] = [
        // macOS / AppKit global chords.
        KeyChord(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey), label: "⌘Q"),
        KeyChord(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(cmdKey), label: "⌘W"),
        KeyChord(keyCode: UInt32(kVK_Tab), modifiers: UInt32(cmdKey), label: "⌘⇥"),
        KeyChord(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey), label: "⌘Space"),
        KeyChord(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey), label: "⌘H"),
        KeyChord(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey), label: "⌘M"),
        // Main/Edit menu keyEquivalents: AppKit consumes these before any
        // local monitor sees them, so they can never be recorded reliably.
        KeyChord(keyCode: UInt32(kVK_ANSI_Comma), modifiers: UInt32(cmdKey), label: "⌘,"),
        KeyChord(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey), label: "⌘R"),
        KeyChord(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(cmdKey), label: "⌘Z"),
        KeyChord(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(cmdKey | shiftKey), label: "⇧⌘Z"),
        KeyChord(keyCode: UInt32(kVK_ANSI_X), modifiers: UInt32(cmdKey), label: "⌘X"),
        KeyChord(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey), label: "⌘C"),
        KeyChord(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey), label: "⌘V"),
        KeyChord(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey), label: "⌘A")
    ]

    /// Pure validation shared by the recorder, Settings and the probe.
    /// nil = accepted, otherwise a user-readable reason.
    static func rejection(for combo: KeyChord,
                          role: HotKeyRole,
                          settings: Settings) -> String? {
        if combo.keyCode == UInt32(kVK_Escape) {
            return "Esc 用于关闭面板，不能作为快捷键"
        }
        guard combo.isValid(allowsBareKeys: role.allowsBareKeys,
                            allowsBareFunctionKeys: role.allowsBareFunctionKeys) else {
            if role.allowsBareKeys {
                return "这个按键不能作为快捷键，请换一个"
            }
            return role.allowsBareFunctionKeys
                ? "请按住 ⌘ / ⌃ / ⌥ / ⇧ 中的至少一个修饰键，或使用 F1–F15 功能键"
                : "请同时按住 ⌘ / ⌃ / ⌥ / ⇧ 中的至少一个修饰键"
        }
        if systemReserved.contains(where: { combo.hasSameCombo(as: $0) }) {
            return "这是系统或菜单保留的组合，请换一个"
        }
        for other in HotKeyRole.allCases where other != role {
            if combo.hasSameCombo(as: other.chord(in: settings)) {
                return "该组合已被「\(other.title)」占用"
            }
        }
        if role != .launcher,
           settings.launcherHotKey.hasSameCombo(as: .defaultLauncher),
           KeyChord.legacyAlternates.contains(where: { combo.hasSameCombo(as: $0) }) {
            return "该组合是内置备用启动键，请先更改「显示启动台」"
        }
        return nil
    }
}
