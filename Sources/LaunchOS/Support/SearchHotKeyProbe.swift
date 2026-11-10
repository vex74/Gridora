import AppKit
import Carbon.HIToolbox
import Foundation

/// Deterministic assertions for `Gridora --search-hotkey-probe`. Everything is
/// a pure function of Settings / SearchHotKey / AppInfo, except the last group
/// which drives the real `LauncherModel.handleKey` with synthetic key events.
/// Writes one log and returns the overall result.
@MainActor
enum SearchHotKeyProbe {
    static let logPath = "/tmp/launchos-search-hotkey.log"

    @discardableResult
    static func run(model: LauncherModel) -> Bool {
        var lines: [String] = ["SEARCH HOTKEY PROBE"]
        var all = true
        func check(_ tag: String, _ ok: Bool, _ detail: String) {
            lines.append("\(tag) \(ok ? "PASS" : "FAIL") \(detail)")
            if !ok { all = false }
        }
        func event(_ code: UInt16, _ chars: String,
                   _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                             timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: 0, context: nil, characters: chars,
                             charactersIgnoringModifiers: chars,
                             isARepeat: false, keyCode: code)!
        }
        func app(_ name: String, _ id: String, pinyin: String, initials: String,
                 aliases: [String]) -> AppInfo {
            AppInfo(bundleID: id, name: name, path: "/Applications/\(id).app",
                    pinyin: pinyin, pinyinInitials: initials, aliases: aliases,
                    romanizedAliases: [], romanizedInitials: [], icon: NSImage())
        }

        // A. The default chord is ⌘F, matches only with the Command flag, and
        // never overlaps the hard-wired global launcher chord.
        let def = SearchHotKey.default
        let cmdF = event(UInt16(kVK_ANSI_F), "f", [.command])
        let plainF = event(UInt16(kVK_ANSI_F), "f")
        check("A default", def == SearchHotKey(keyCode: UInt32(kVK_ANSI_F),
                                               modifiers: UInt32(cmdKey), label: "⌘F")
              && def.matches(cmdF) && !def.matches(plainF)
              && def.isValid && !def.conflictsWithLauncherChord,
              "label=\(def.label) cmd=\(def.matches(cmdF)) plain=\(def.matches(plainF))")

        // A2. A recorded combo survives a Codable round trip and matches only
        // its own flags/keyCode.
        let custom = SearchHotKey(keyCode: UInt32(kVK_ANSI_K),
                                  modifiers: UInt32(cmdKey | shiftKey), label: "⇧⌘K")
        let shiftCmdK = event(UInt16(kVK_ANSI_K), "k", [.command, .shift])
        let encoded = try? JSONEncoder().encode(custom)
        let decoded = encoded.flatMap { try? JSONDecoder().decode(SearchHotKey.self, from: $0) }
        check("A2 roundtrip", decoded == custom && custom.matches(shiftCmdK)
              && !custom.matches(cmdF) && SearchHotKey.from(shiftCmdK).label == "⇧⌘K",
              "decoded=\(decoded?.label ?? "nil") captured=\(SearchHotKey.from(shiftCmdK).label)")

        // B. An old state.json without the two new keys upgrades to the safe
        // behaviour: letters do not open search, chord stays ⌘F.
        let legacy = #"{"pages":[],"hidden":[],"settings":{"columns":9,"rows":7,"iconScale":1.4},"usage":{},"manualHidden":[],"pinned":[]}"#
        let oldState = try? JSONDecoder().decode(PersistedState.self,
                                                 from: Data(legacy.utf8))
        check("B legacy upgrade",
              oldState?.settings.letterOpensSearch == false
              && oldState?.settings.searchHotKey == .default
              && oldState?.settings.columns == 9,
              "letter=\(oldState?.settings.letterOpensSearch ?? true) chord=\(oldState?.settings.searchHotKey.label ?? "nil")")

        // B2. A corrupt stored chord falls back to ⌘F instead of breaking the
        // whole state file.
        let corrupt = #"{"pages":[],"hidden":[],"settings":{"searchHotKey":{"keyCode":999,"modifiers":0,"label":""}},"usage":{},"manualHidden":[],"pinned":[]}"#
        let broken = try? JSONDecoder().decode(PersistedState.self,
                                               from: Data(corrupt.utf8))
        check("B2 corrupt chord", broken?.settings.searchHotKey == .default,
              "chord=\(broken?.settings.searchHotKey.label ?? "nil")")

        // C. Unicode whitespace tokenisation: a full-width IME space must
        // split into two tokens, and repeated spaces must not create empties.
        let t1 = LauncherModel.searchTokens("微信\u{3000}助手")
        let t2 = LauncherModel.searchTokens("  Google   Chrome  ")
        let t3 = LauncherModel.searchTokens("   ")
        check("C tokenising", t1 == ["微信", "助手"]
              && t2 == ["google", "chrome"] && t3.isEmpty,
              "t1=\(t1) t2=\(t2) t3=\(t3)")

        // D. Short-token relevance. Before this change a single ASCII letter
        // hit `n.contains(t)` = 160 before pinyin (=120), so typing "h"
        // surfaced "Photos" ahead of 「洪恩」. Reproduce the old chain here as
        // a negative control, then assert the shipped one ranks it correctly.
        let photos = app("Photos", "com.apple.photos", pinyin: "photos",
                         initials: "p", aliases: ["photos"])
        let hongen = app("洪恩", "com.hongen.demo", pinyin: "hongen",
                         initials: "he", aliases: ["洪恩"])
        let oldPhotos = legacyScore(photos, "h"), oldHongen = legacyScore(hongen, "h")
        let newPhotos = photos.searchScore(for: ["h"])
        let newHongen = hongen.searchScore(for: ["h"])
        check("D short relevance",
              oldPhotos > oldHongen && newHongen > newPhotos,
              "legacy photos=\(oldPhotos) hongen=\(oldHongen) | shipped photos=\(newPhotos) hongen=\(newHongen)")
        check("D2 long unchanged", photos.searchScore(for: ["pho"]) == 200
              && hongen.searchScore(for: ["hong"]) == 120,
              "photos/pho=\(photos.searchScore(for: ["pho"])) hongen/hong=\(hongen.searchScore(for: ["hong"]))")

        // E. Real key handling: the configured chord opens search, letters do
        // not when the switch is off, and they do when it is on.
        let savedChord = model.settings.searchHotKey
        let savedLetter = model.settings.letterOpensSearch
        defer {
            model.closeSearch()
            model.settings.searchHotKey = savedChord
            model.settings.letterOpensSearch = savedLetter
        }

        model.closeSearch()
        model.settings.searchHotKey = .default
        model.settings.letterOpensSearch = false
        let opened = model.handleKey(cmdF, textEditing: false)
        check("E chord opens", opened && model.searchOpen,
              "consumed=\(opened) open=\(model.searchOpen)")

        model.closeSearch()
        let letterW = event(UInt16(kVK_ANSI_W), "w")
        let blocked = model.handleKey(letterW, textEditing: false)
        check("E2 letter blocked", !blocked && !model.searchOpen,
              "consumed=\(blocked) open=\(model.searchOpen)")

        model.settings.letterOpensSearch = true
        let allowed = model.handleKey(letterW, textEditing: false)
        check("E3 letter opt-in", allowed && model.searchOpen && model.query == "w",
              "consumed=\(allowed) open=\(model.searchOpen) query=\(model.query.debugDescription)")

        model.closeSearch()
        model.settings.searchHotKey = custom
        let customOpened = model.handleKey(shiftCmdK, textEditing: false)
        check("E4 custom live", customOpened && model.searchOpen,
              "consumed=\(customOpened) open=\(model.searchOpen)")

        // E5. While search is open the chord must not tear the session down.
        model.openSearch("微信")
        let before = model.query
        let inSearch = model.handleKey(event(UInt16(kVK_ANSI_F), "f", [.command]),
                                       textEditing: false)
        check("E5 in-search stable", inSearch && model.searchOpen && model.query == before,
              "open=\(model.searchOpen) query=\(model.query.debugDescription)")

        // F. Recorded combos that collide with GlobalHotKey are rejected.
        let clash = SearchHotKey(keyCode: UInt32(kVK_Space),
                                 modifiers: UInt32(controlKey | optionKey),
                                 label: "⌃⌥Space")
        let bare = SearchHotKey(keyCode: UInt32(kVK_ANSI_F), modifiers: 0, label: "F")
        check("F collisions", clash.conflictsWithLauncherChord && !bare.isValid,
              "clash=\(clash.conflictsWithLauncherChord) bareValid=\(bare.isValid)")

        lines.append(all ? "PASS" : "FAIL")
        lines.append("DONE")
        try? (lines.joined(separator: "\n") + "\n")
            .write(toFile: logPath, atomically: true, encoding: .utf8)
        return all
    }

    /// The pre-change scoring chain, kept here only as a negative control so
    /// group D cannot pass on a detector that never fails.
    private static func legacyScore(_ a: AppInfo, _ t: String) -> Int {
        let n = a.name.lowercased()
        if n == t { return 240 }
        if a.aliases.contains(where: { $0 == t }) { return 220 }
        if n.hasPrefix(t) { return 200 }
        if a.aliases.contains(where: { $0.hasPrefix(t) }) { return 180 }
        if n.contains(t) { return 160 }
        if a.pinyinInitials == t { return 155 }
        if a.pinyin == t { return 150 }
        if a.pinyin.hasPrefix(t) { return 120 }
        if a.romanizedInitials.contains(where: { $0 == t }) { return 115 }
        if a.pinyinInitials.hasPrefix(t) { return 110 }
        if a.romanizedAliases.contains(where: { $0 == t }) { return 105 }
        if a.aliases.contains(where: { $0.contains(t) }) { return 100 }
        if a.pinyin.contains(t) { return 75 }
        if a.romanizedInitials.contains(where: { $0.hasPrefix(t) }) { return 70 }
        if a.romanizedAliases.contains(where: { $0.hasPrefix(t) }) { return 60 }
        if a.romanizedAliases.contains(where: { $0.contains(t) }) { return 40 }
        if t.count >= 3, a.bundleID.lowercased().contains(t) { return 10 }
        return 0
    }
}
