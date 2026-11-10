import AppKit
import Carbon.HIToolbox
import Foundation

/// Assertions for `Gridora --launcher-hotkey-probe`.
///
/// Every "live" assertion drives a real entry point: `AppDelegate.applyLauncherHotKey()`
/// for the Carbon registration, `LauncherModel.handleKey` for paging/search,
/// `StateStore`/`PersistedState` decoding for upgrades, and `HotKeyRecorder`
/// arming for the recorder. Pure helpers (KeyChord / HotKeyRules) are used only
/// where no AppKit window is involved, which is the case in a headless probe.
@MainActor
enum LauncherHotKeyProbe {
    static let logPath = "/tmp/launchos-launcher-hotkey.log"

    @discardableResult
    static func run(model: LauncherModel, delegate: AppDelegate) -> Bool {
        var lines: [String] = ["LAUNCHER HOTKEY PROBE"]
        var all = true
        func check(_ tag: String, _ ok: Bool, _ detail: String) {
            lines.append("\(tag) \(ok ? "PASS" : "FAIL") \(detail)")
            if !ok { all = false }
        }
        func info(_ text: String) { lines.append("INFO \(text)") }
        func event(_ code: UInt16, _ chars: String = "",
                   _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                             timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: 0, context: nil, characters: chars,
                             charactersIgnoringModifiers: chars,
                             isARepeat: false, keyCode: code)!
        }
        func chordJSON(_ c: KeyChord) -> String {
            "{\"keyCode\":\(c.keyCode),\"modifiers\":\(c.modifiers),\"label\":\"\(c.label)\"}"
        }
        func decode(_ settings: String) -> Settings? {
            let json = "{\"pages\":[],\"hidden\":[],\"settings\":\(settings),"
                + "\"usage\":{},\"manualHidden\":[],\"pinned\":[]}"
            return (try? JSONDecoder().decode(PersistedState.self,
                                              from: Data(json.utf8)))?.settings
        }

        // MARK: A — chord model, bare F-keys, labels and exact matching
        let defaults = Settings()
        let f3Event = event(UInt16(kVK_F3))
        let f3 = KeyChord.from(f3Event)
        let cmdF = event(UInt16(kVK_ANSI_F), "f", [.command])
        let plainF = event(UInt16(kVK_ANSI_F), "f")
        let bareA = KeyChord.from(event(UInt16(kVK_ANSI_A), "a"))
        let bareDigit = KeyChord.from(event(UInt16(kVK_ANSI_1), "1"))
        let bareSpace = KeyChord.from(event(UInt16(kVK_Space), " "))
        let bareModifier = KeyChord(keyCode: UInt32(kVK_Command), modifiers: 0, label: "⌘")
        let implausible = KeyChord(keyCode: 999, modifiers: 0, label: "X")
        check("A defaults",
              defaults.launcherHotKey == .defaultLauncher
              && defaults.previousPageHotKey == .defaultPreviousPage
              && defaults.nextPageHotKey == .defaultNextPage
              && defaults.searchHotKey == .defaultSearch,
              "launcher=\(defaults.launcherHotKey.label) prev=\(defaults.previousPageHotKey.label)"
              + " next=\(defaults.nextPageHotKey.label) search=\(defaults.searchHotKey.label)")
        check("A F3 bare",
              f3.label == "F3" && f3.modifiers == 0 && f3.keyCode == UInt32(kVK_F3)
              && f3.isValid(allowsBareFunctionKeys: true)
              && !f3.isValid(allowsBareFunctionKeys: false)
              && !f3.isValid
              && !f3.conflictsWithLauncherChord,
              "label=\(f3.label) code=\(f3.keyCode) mods=\(f3.modifiers)")
        check("A single keys accepted for launcher",
              bareA.isValid(allowsBareKeys: true)
              && bareDigit.isValid(allowsBareKeys: true)
              && bareSpace.isValid(allowsBareKeys: true)
              && bareA.label == "A" && bareDigit.label == "1" && bareSpace.label == "Space"
              && KeyChord.defaultSearch.matches(cmdF)
              && !KeyChord.defaultSearch.matches(plainF)
              && KeyChord.defaultSearch.isValid,
              "A=\(bareA.label) digit=\(bareDigit.label) space=\(bareSpace.label)"
              + " cmdF=\(KeyChord.defaultSearch.matches(cmdF))")
        check("A single keys rejected for in-app roles",
              !bareA.isValid(allowsBareFunctionKeys: true)
              && !bareSpace.isValid(allowsBareFunctionKeys: true)
              && !bareA.isValid
              && HotKeyRules.rejection(for: bareA, role: .search, settings: defaults) != nil
              && HotKeyRules.rejection(for: bareDigit, role: .previousPage, settings: defaults) != nil
              && HotKeyRules.rejection(for: bareSpace, role: .nextPage, settings: defaults) != nil
              && HotKeyRules.rejection(for: bareA, role: .launcher, settings: defaults) == nil,
              "search=\(HotKeyRules.rejection(for: bareA, role: .search, settings: defaults) ?? "nil")"
              + " launcher=\(HotKeyRules.rejection(for: bareA, role: .launcher, settings: defaults) ?? "nil")")
        check("A implausible keys rejected",
              !implausible.isValid(allowsBareKeys: true)
              && !bareModifier.isValid(allowsBareKeys: true)
              && HotKeyRules.rejection(for: implausible, role: .launcher, settings: defaults) != nil
              && HotKeyRules.rejection(for: bareModifier, role: .launcher, settings: defaults) != nil,
              "key999=\(HotKeyRules.rejection(for: implausible, role: .launcher, settings: defaults) ?? "nil")"
              + " cmdOnly=\(HotKeyRules.rejection(for: bareModifier, role: .launcher, settings: defaults) ?? "nil")")
        check("A label mapping",
              KeyChord.from(event(UInt16(kVK_LeftArrow), "", [.command])).label == "⌘←"
              && KeyChord.from(event(UInt16(kVK_F12))).label == "F12"
              && KeyChord.from(event(UInt16(kVK_Escape))).label == "Esc",
              "left=\(KeyChord.from(event(UInt16(kVK_LeftArrow), "", [.command])).label)"
              + " f12=\(KeyChord.from(event(UInt16(kVK_F12))).label)")

        // MARK: B — state.json upgrade, corruption, nulls and conflicts
        let legacy = decode("{\"columns\":9,\"rows\":7,\"iconScale\":1.4}")
        check("B legacy upgrade",
              legacy?.launcherHotKey == .defaultLauncher
              && legacy?.previousPageHotKey == .defaultPreviousPage
              && legacy?.nextPageHotKey == .defaultNextPage
              && legacy?.searchHotKey == .defaultSearch
              && legacy?.columns == 9,
              "launcher=\(legacy?.launcherHotKey.label ?? "nil") columns=\(legacy?.columns ?? -1)")

        let shiftCmdBracket = KeyChord(keyCode: UInt32(kVK_ANSI_LeftBracket),
                                       modifiers: UInt32(cmdKey | shiftKey), label: "⇧⌘[")
        let shiftCmdCloseBracket = KeyChord(keyCode: UInt32(kVK_ANSI_RightBracket),
                                            modifiers: UInt32(cmdKey | shiftKey), label: "⇧⌘]")
        let cmdK = KeyChord(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey), label: "⌘K")
        let customJSON = "{\"launcherHotKey\":\(chordJSON(f3)),"
            + "\"previousPageHotKey\":\(chordJSON(shiftCmdBracket)),"
            + "\"nextPageHotKey\":\(chordJSON(shiftCmdCloseBracket)),"
            + "\"searchHotKey\":\(chordJSON(cmdK))}"
        let custom = decode(customJSON)
        check("B custom roundtrip",
              custom?.launcherHotKey == f3
              && custom?.previousPageHotKey == shiftCmdBracket
              && custom?.nextPageHotKey == shiftCmdCloseBracket
              && custom?.searchHotKey == cmdK,
              "launcher=\(custom?.launcherHotKey.label ?? "nil") search=\(custom?.searchHotKey.label ?? "nil")")

        let bareState = decode("{\"launcherHotKey\":\(chordJSON(bareA)),"
            + "\"previousPageHotKey\":\(chordJSON(KeyChord.alternatePreviousPage))}")
        check("B bare launcher state upgrade",
              bareState?.launcherHotKey == bareA
              && bareState?.previousPageHotKey == KeyChord.alternatePreviousPage
              && bareState?.searchHotKey == .defaultSearch,
              "launcher=\(bareState?.launcherHotKey.label ?? "nil")"
              + " prev=\(bareState?.previousPageHotKey.label ?? "nil")")

        let corrupt = decode("{\"launcherHotKey\":{\"keyCode\":999,\"modifiers\":0,\"label\":\"\"}}")
        let nullValue = decode("{\"launcherHotKey\":null,\"searchHotKey\":{\"keyCode\":999,\"modifiers\":0,\"label\":\"\"}}")
        check("B corrupt/null fallback",
              corrupt?.launcherHotKey == .defaultLauncher
              && nullValue?.launcherHotKey == .defaultLauncher
              && nullValue?.searchHotKey == .defaultSearch,
              "corrupt=\(corrupt?.launcherHotKey.label ?? "nil") null=\(nullValue?.launcherHotKey.label ?? "nil")")

        // A launcher chord that steals ⌘F must push search onto its alternate,
        // not leave both roles on the same physical chord.
        let cmdFChord = KeyChord.defaultSearch
        let clash = decode("{\"launcherHotKey\":\(chordJSON(cmdFChord))}")
        check("B launcher/search collision",
              clash?.launcherHotKey == cmdFChord
              && clash?.searchHotKey == KeyChord.alternateSearch,
              "launcher=\(clash?.launcherHotKey.label ?? "nil") search=\(clash?.searchHotKey.label ?? "nil")")

        let prevClash = decode("{\"previousPageHotKey\":\(chordJSON(KeyChord.defaultNextPage)),"
            + "\"nextPageHotKey\":\(chordJSON(KeyChord.defaultNextPage))}")
        check("B paging collision",
              prevClash?.previousPageHotKey == .defaultNextPage
              && prevClash?.nextPageHotKey == KeyChord.alternateNextPage,
              "prev=\(prevClash?.previousPageHotKey.label ?? "nil") next=\(prevClash?.nextPageHotKey.label ?? "nil")")

        // MARK: C — real Carbon registration + Settings callback + menu title
        let savedSettings = model.settings
        defer {
            model.settings = savedSettings
            delegate.applyLauncherHotKey()
        }
        delegate.applyLauncherHotKey()
        let defaultLabels = GlobalHotKey.shared.registeredCombos.map(\.label)
        check("C default registration",
              defaultLabels == ["⌃⌥Space", "⌃⌥L", "F4"]
              && delegate.launcherMenuItemTitle.contains("⌃⌥Space"),
              "combos=\(defaultLabels) menu=\(delegate.launcherMenuItemTitle)")
        info("C carbon default status=\(GlobalHotKey.shared.lastStatus)"
             + " active=\(GlobalHotKey.shared.activeRegistrationCount)/\(defaultLabels.count)"
             + " hasAny=\(GlobalHotKey.shared.hasAnyHotKey)")

        // This is the exact closure SettingsOverlay.onChange fires.
        model.settings.launcherHotKey = f3
        model.onHotKeysChanged?()
        let customLabels = GlobalHotKey.shared.registeredCombos.map(\.label)
        check("C custom via callback",
              customLabels == ["F3"]
              && delegate.launcherMenuItemTitle.contains("F3")
              && GlobalHotKey.shared.activeRegistrationCount == 1
              && !GlobalHotKey.shared.lastRegistrationFailed,
              "combos=\(customLabels) menu=\(delegate.launcherMenuItemTitle)"
              + " status=\(GlobalHotKey.shared.lastStatus)"
              + " active=\(GlobalHotKey.shared.activeRegistrationCount)")
        info("C carbon F3 status=\(GlobalHotKey.shared.lastStatus)")

        // A single plain key must really be claimable by Carbon, not just
        // accepted by the pure validation rules. This is the assertion that
        // proves "no chord required" works on a real Mac.
        model.settings.launcherHotKey = bareA
        model.onHotKeysChanged?()
        let bareLabels = GlobalHotKey.shared.registeredCombos.map(\.label)
        check("C bare letter registered (real Carbon)",
              bareLabels == [bareA.label]
              && GlobalHotKey.shared.lastStatus == noErr
              && GlobalHotKey.shared.activeRegistrationCount == 1
              && delegate.launcherMenuItemTitle.contains(bareA.label),
              "combos=\(bareLabels) status=\(GlobalHotKey.shared.lastStatus)"
              + " active=\(GlobalHotKey.shared.activeRegistrationCount)"
              + " menu=\(delegate.launcherMenuItemTitle)")
        info("C carbon bare A status=\(GlobalHotKey.shared.lastStatus)")

        model.settings.launcherHotKey = bareSpace
        model.onHotKeysChanged?()
        check("C bare space registered (real Carbon)",
              GlobalHotKey.shared.registeredCombos.map(\.label) == [bareSpace.label]
              && GlobalHotKey.shared.lastStatus == noErr
              && GlobalHotKey.shared.activeRegistrationCount == 1
              && delegate.launcherMenuItemTitle.contains(bareSpace.label),
              "combos=\(GlobalHotKey.shared.registeredCombos.map(\.label))"
              + " status=\(GlobalHotKey.shared.lastStatus)"
              + " active=\(GlobalHotKey.shared.activeRegistrationCount)")
        info("C carbon bare Space status=\(GlobalHotKey.shared.lastStatus)")

        model.settings.launcherHotKey = f3
        model.onHotKeysChanged?()
        delegate.applyLauncherHotKey()
        check("C re-register idempotent",
              GlobalHotKey.shared.registeredCombos.map(\.label) == ["F3"],
              "combos=\(GlobalHotKey.shared.registeredCombos.map(\.label))")
        model.settings = savedSettings
        delegate.applyLauncherHotKey()
        check("C restore default",
              GlobalHotKey.shared.registeredCombos.map(\.label) == ["⌃⌥Space", "⌃⌥L", "F4"],
              "combos=\(GlobalHotKey.shared.registeredCombos.map(\.label))")

        // MARK: D — real key monitor decisions for paging and search
        let savedPages = model.pages
        let savedArea = model.areaSize
        let savedSearch = model.settings.searchHotKey
        let savedLetter = model.settings.letterOpensSearch
        let savedLauncher = model.settings.launcherHotKey
        defer {
            model.closeSearch()
            model.pages = savedPages
            model.areaSize = savedArea
            model.settings.searchHotKey = savedSearch
            model.settings.letterOpensSearch = savedLetter
            model.settings.launcherHotKey = savedLauncher
        }
        model.pages = [[], [], []]
        model.areaSize = CGSize(width: 1200, height: 800)
        model.settings = savedSettings
        model.settingsOpen = false
        model.hiddenOpen = false
        model.openFolderID = nil
        model.closeSearch()

        let cmdLeft = event(UInt16(kVK_LeftArrow), "", [.command])
        let cmdRight = event(UInt16(kVK_RightArrow), "", [.command])
        check("D default paging",
              model.handleKey(cmdLeft, textEditing: false)
              && model.handleKey(cmdRight, textEditing: false),
              "cmdLeft/cmdRight consumed by the shipped defaults")

        var paging = model.settings
        paging.previousPageHotKey = shiftCmdBracket
        paging.nextPageHotKey = shiftCmdCloseBracket
        model.settings = paging
        let customPrev = event(UInt16(kVK_ANSI_LeftBracket), "[", [.command, .shift])
        let customNext = event(UInt16(kVK_ANSI_RightBracket), "]", [.command, .shift])
        let customPrevConsumed = model.handleKey(customPrev, textEditing: false)
        let customNextConsumed = model.handleKey(customNext, textEditing: false)
        let oldDefaultConsumed = model.handleKey(cmdLeft, textEditing: false)
        check("D custom paging replaces hardcoded",
              customPrevConsumed && customNextConsumed && !oldDefaultConsumed,
              "customPrev=\(customPrevConsumed) customNext=\(customNextConsumed)"
              + " oldDefault=\(oldDefaultConsumed) page=\(model.currentPage)")

        // Search chord must still be independent and the letter switch intact.
        model.settings.searchHotKey = .defaultSearch
        model.settings.letterOpensSearch = false
        model.closeSearch()
        let opened = model.handleKey(cmdF, textEditing: false)
        check("D search independent", opened && model.searchOpen,
              "consumed=\(opened) open=\(model.searchOpen)")
        model.closeSearch()
        let letter = model.handleKey(event(UInt16(kVK_ANSI_W), "w"), textEditing: false)
        check("D letters still opt-in", !letter && !model.searchOpen,
              "consumed=\(letter)")

        // A single-key launcher chord is also a plain letter/space to the
        // grid: with letterOpensSearch on, "A" would open search, and Space
        // would activate the selected app -- at the same moment Carbon hides
        // the launcher. The local monitor must yield to the global hot key.
        var bareGrid = model.settings
        bareGrid.launcherHotKey = bareA
        bareGrid.letterOpensSearch = true
        model.settings = bareGrid
        model.closeSearch()
        let bareLetter = model.handleKey(event(UInt16(kVK_ANSI_A), "a"), textEditing: false)
        check("D bare launcher key not treated as typing",
              bareLetter && !model.searchOpen,
              "consumed=\(bareLetter) searchOpen=\(model.searchOpen)")
        bareGrid.launcherHotKey = bareSpace
        model.settings = bareGrid
        model.closeSearch()
        let bareSpaceKey = model.handleKey(event(UInt16(kVK_Space), " "), textEditing: false)
        check("D bare launcher Space not acted on",
              bareSpaceKey && !model.searchOpen,
              "consumed=\(bareSpaceKey) searchOpen=\(model.searchOpen)")

        // MARK: E — recorder validation (pure, shared with Settings)
        var rulesSettings = Settings()
        let cmdQ = KeyChord(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey), label: "⌘Q")
        let cmdR = KeyChord(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey), label: "⌘R")
        let f4Chord = KeyChord(keyCode: UInt32(kVK_F4), modifiers: 0, label: "F4")
        // ⌃⌥L carries modifiers, so it is a valid *search* candidate. Using
        // bare F4 here would only prove that search rejects bare keys, which
        // is a different rule (and made the "spare released" check a false
        // negative on the first run).
        let spareChord = KeyChord(keyCode: UInt32(kVK_ANSI_L),
                                  modifiers: UInt32(controlKey | optionKey), label: "⌃⌥L")
        let esc = KeyChord.from(event(UInt16(kVK_Escape)))
        check("E launcher F3 accepted",
              HotKeyRules.rejection(for: f3, role: .launcher, settings: rulesSettings) == nil,
              "reason=\(HotKeyRules.rejection(for: f3, role: .launcher, settings: rulesSettings) ?? "nil")")
        check("E collisions + system reserved rejected",
              HotKeyRules.rejection(for: cmdFChord, role: .launcher, settings: rulesSettings) != nil
              && HotKeyRules.rejection(for: cmdQ, role: .launcher, settings: rulesSettings) != nil
              && HotKeyRules.rejection(for: cmdR, role: .launcher, settings: rulesSettings) != nil
              && HotKeyRules.rejection(for: esc, role: .launcher, settings: rulesSettings) != nil
              && HotKeyRules.rejection(for: implausible, role: .launcher, settings: rulesSettings) != nil,
              "cmdF=\(HotKeyRules.rejection(for: cmdFChord, role: .launcher, settings: rulesSettings) ?? "nil")"
              + " cmdQ=\(HotKeyRules.rejection(for: cmdQ, role: .launcher, settings: rulesSettings) ?? "nil")")
        check("E bare launcher accepted / in-app roles still guarded",
              HotKeyRules.rejection(for: bareA, role: .launcher, settings: rulesSettings) == nil
              && HotKeyRules.rejection(for: bareDigit, role: .launcher, settings: rulesSettings) == nil
              && HotKeyRules.rejection(for: bareSpace, role: .launcher, settings: rulesSettings) == nil
              && HotKeyRules.rejection(for: bareA, role: .search, settings: rulesSettings) != nil
              && HotKeyRules.rejection(for: bareDigit, role: .previousPage, settings: rulesSettings) != nil,
              "bareA.launcher=\(HotKeyRules.rejection(for: bareA, role: .launcher, settings: rulesSettings) ?? "nil")"
              + " bareA.search=\(HotKeyRules.rejection(for: bareA, role: .search, settings: rulesSettings) ?? "nil")")
        check("E legacy spare occupied",
              HotKeyRules.rejection(for: spareChord, role: .search, settings: rulesSettings) != nil
              && HotKeyRules.rejection(for: KeyChord.defaultNextPage,
                                       role: .previousPage, settings: rulesSettings) != nil
              && HotKeyRules.rejection(for: f4Chord, role: .launcher, settings: rulesSettings) == nil,
              "spare=\(HotKeyRules.rejection(for: spareChord, role: .search, settings: rulesSettings) ?? "nil")"
              + " bareF4Launcher=\(HotKeyRules.rejection(for: f4Chord, role: .launcher, settings: rulesSettings) ?? "nil")")
        rulesSettings.launcherHotKey = f3
        check("E spare released on custom launcher",
              HotKeyRules.rejection(for: spareChord, role: .search, settings: rulesSettings) == nil,
              "reason=\(HotKeyRules.rejection(for: spareChord, role: .search, settings: rulesSettings) ?? "nil")")

        // MARK: F — recorder arms / disarms through its real entry point
        HotKeyRecorder.begin(validate: { _ in nil }) { _, _ in }
        let armed = HotKeyRecorder.isRecording
        HotKeyRecorder.cancel()
        check("F recorder lifecycle", armed && !HotKeyRecorder.isRecording,
              "armed=\(armed) released=\(!HotKeyRecorder.isRecording)")

        // MARK: G — all four chords survive encode/decode of a full state
        var persisted = Settings()
        persisted.launcherHotKey = f3
        persisted.previousPageHotKey = shiftCmdBracket
        persisted.nextPageHotKey = shiftCmdCloseBracket
        persisted.searchHotKey = cmdK
        let encoded = try? JSONEncoder().encode(persisted)
        let decoded = encoded.flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
        check("G codable roundtrip",
              decoded?.launcherHotKey == f3
              && decoded?.previousPageHotKey == shiftCmdBracket
              && decoded?.nextPageHotKey == shiftCmdCloseBracket
              && decoded?.searchHotKey == cmdK,
              "encoded=\(encoded?.count ?? 0)B launcher=\(decoded?.launcherHotKey.label ?? "nil")")

        var barePersisted = Settings()
        barePersisted.launcherHotKey = bareA
        let bareEncoded = try? JSONEncoder().encode(barePersisted)
        let bareDecoded = bareEncoded.flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
        check("G bare key codable roundtrip",
              bareDecoded?.launcherHotKey == bareA
              && bareDecoded?.launcherHotKey.modifiers == 0,
              "encoded=\(bareEncoded?.count ?? 0)B launcher=\(bareDecoded?.launcherHotKey.label ?? "nil")")

        lines.append(all ? "PASS" : "FAIL")
        lines.append("DONE")
        try? (lines.joined(separator: "\n") + "\n")
            .write(toFile: logPath, atomically: true, encoding: .utf8)
        return all
    }
}
