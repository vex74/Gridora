import AppKit
import Foundation

/// Development-only harness used by the `--self-test` and `--demo-drag`
/// launch arguments. It writes to /tmp/launchos-debug.log so the interaction
/// engine can be verified without a human at the mouse.
@MainActor
extension LauncherModel {
    /// Merge/drag resolution tracing for self-test and LAUNCHOS_TRACE runs.
    var debugTraceEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--self-test")
            || ProcessInfo.processInfo.environment["LAUNCHOS_TRACE"] == "1"
    }

    func debugLog(_ text: String) {
        let line = "[\(Date().formatted(date: .omitted, time: .standard))] \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/launchos-debug.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    private func debugKey(_ code: UInt16, _ characters: String = "",
                          modifiers: NSEvent.ModifierFlags = []) {
        guard let event = NSEvent.keyEvent(with: .keyDown,
                                          location: .zero,
                                          modifierFlags: modifiers,
                                          timestamp: 0,
                                          windowNumber: 0,
                                          context: nil,
                                          characters: characters,
                                          charactersIgnoringModifiers: characters,
                                          isARepeat: false,
                                          keyCode: code) else { return }
        _ = handleKey(event, textEditing: false)
    }

    func runSelfTest() {
        try? FileManager.default.removeItem(atPath: "/tmp/launchos-debug.log")
        debugLog("start area=\(areaSize) pages=\(pages.count) apps=\(appsByID.count) columns=\(settings.columns) rows=\(settings.rows)")

        guard let firstPage = pages.first, firstPage.count >= 6 else {
            debugLog("FAIL: not enough tiles")
            return
        }
        let m = metrics
        let start = m.iconCenter(of: 0)

        // Hit-testing: icon art only, empty cell space is inert.
        let blank = CGPoint(x: m.center(of: 2).x + m.cellW * 0.45,
                            y: m.center(of: 2).y + m.cellH * 0.42)
        debugLog("hit icon=\(m.iconIndex(at: m.iconCenter(of: 2), count: 6).map(String.init) ?? "nil") blank=\(m.iconIndex(at: blank, count: 6).map(String.init) ?? "nil")")
        pointerDown(at: blank)
        debugLog("blank-press tile=\(press?.tileID ?? "nil")")
        press = nil

        let before = pages[0].prefix(6).map { $0.bundleID ?? "FOLDER" }
        // Pure reorder: drop in the gap right of tile 4, never on an icon.
        let gap = CGPoint(x: m.iconCenter(of: 4).x + m.cellW * 0.36,
                          y: m.iconCenter(of: 4).y + m.cellH * 0.30)
        pointerDown(at: start)
        pointerDragged(from: start, to: CGPoint(x: start.x + 12, y: start.y + 12))
        pointerDragged(from: start, to: gap)
        let after = pages[0].prefix(6).map { $0.bundleID ?? "FOLDER" }
        debugLog("drag-before=\(before)")
        debugLog("drag-after =\(after) dragging=\(drag?.tileID ?? "nil") merge=\(drag?.mergeTarget ?? "nil")")
        pointerUp(at: gap)
        debugLog("drop: drag=\(drag == nil ? "cleared" : "active") press=\(press == nil ? "cleared" : "active")")

        // Folder creation: drag tile 0 onto tile 1
        if pages[0].count >= 2, pages[0][0].bundleID != nil, pages[0][1].bundleID != nil {
            let a = m.iconCenter(of: 0)
            let b = m.iconCenter(of: 1)
            debugLog("merge-attempt \(pages[0][0].bundleID ?? "?") -> \(pages[0][1].bundleID ?? "?")")
            pointerDown(at: a)
            pointerDragged(from: a, to: CGPoint(x: a.x + 12, y: a.y + 12))
            for step in 1...8 {
                let t = CGFloat(step) / 8
                pointerDragged(from: a, to: CGPoint(x: a.x + (b.x - a.x) * t,
                                                    y: a.y + (b.y - a.y) * t))
            }
            debugLog("merge-target=\(drag?.mergeTarget ?? "nil")")
            pointerUp(at: b)
            debugLog("folder-created=\(pages[0].contains(where: { $0.isFolder }))")
        }

        // Search + keyboard
        openSearch("ca")
        debugLog("search open=\(searchOpen) query=\(query) results=\(searchResults.count) first=\(searchResults.first?.name ?? "-")")
        moveSearchSelection(2)
        debugLog("search selection=\(searchSelection)")
        debugKey(53)
        debugLog("after-esc searchOpen=\(searchOpen)")

        // Letter to open search
        debugKey(0, "w")
        debugLog("letter-open search=\(searchOpen) query=\(query) results=\(searchResults.count)")
        debugKey(53)

        // Paging
        let pageBefore = currentPage
        goToPage(1, animated: false)
        debugLog("page \(pageBefore) -> \(currentPage) scroll=\(scrollPos)")
        goToPage(0, animated: false)

        // macOS 15 Launchpad documents ⌘← / ⌘→ for paging. Assert on the
        // spring's destination rather than the settled page: inside this probe
        // the display-linked animation has not had a frame to run yet.
        let extent = settings.vertical ? m.size.height : m.size.width
        scrollEngine.cancel()
        debugKey(124, modifiers: .command)
        let cmdRight = scrollEngine.destination.map { Int(round($0 / extent)) } ?? -1
        debugLog("cmd-right destination=\(cmdRight) expected=1")
        scrollEngine.cancel()
        goToPage(1, animated: false)
        debugKey(123, modifiers: .command)
        let cmdLeft = scrollEngine.destination.map { Int(round($0 / extent)) } ?? -1
        debugLog("cmd-left destination=\(cmdLeft) expected=0")
        scrollEngine.cancel()
        goToPage(0, animated: false)

        // Selection navigation
        selection = 0
        debugKey(124)
        debugLog("selection after right=\(selection ?? -1)")
        debugKey(125)
        debugLog("selection after down=\(selection ?? -1)")

        // Scroll wheel
        let scrollBefore = scrollPos
        if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -60, wheel2: -90, wheel3: 0),
           let event = NSEvent(cgEvent: cg) {
            debugLog("wheel precise=\(event.hasPreciseScrollingDeltas) dx=\(event.scrollingDeltaX) dy=\(event.scrollingDeltaY) phase=\(event.phase.rawValue)")
            handleScroll(event)
            debugLog("scroll \(scrollBefore) -> \(scrollPos) page=\(currentPage)")
        }

        // Hiding
        if let tile = pages.first?.first {
            let id = tile.id
            hide(tileID: id)
            debugLog("hide \(id): hidden=\(hiddenTiles.count) located=\(locate(id) == nil ? "no" : "yes")")
        }

        // Clicking empty space should ask the window to go away.
        let corner = CGPoint(x: m.cellW * 0.04, y: m.cellH * 0.04)
        debugLog("blank-click-hit=\(m.iconIndex(at: corner, count: pages.first?.count ?? 0).map(String.init) ?? "nil")")

        // A wheel tick with no phase information must settle on a page.
        if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                            wheelCount: 2, wheel1: -30, wheel2: -30, wheel3: 0),
           let event = NSEvent(cgEvent: cg) {
            handleScroll(event)
            debugLog("wheel-partial pos=\(scrollPos)")
            let expected = (scrollPos / pageExtent).rounded() * pageExtent
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.debugLog("wheel-settled pos=\(self.scrollPos) expected=\(expected) page=\(self.currentPage)")
            }
        }

        handleClick(at: corner)
        debugLog("blank-click dispatched")

        debugLog("SELFTEST DONE")
    }

    /// Leaves an active drag on screen so a screenshot can verify the lift,
    /// reflow and drop-target highlight.
    func debugDragDemo() {
        searchOpen = false
        settingsOpen = false
        hiddenOpen = false
        openFolderID = nil
        guard areaSize.width > 1, let page = pages.first, page.count >= 6 else {
            debugLog("drag-demo: not ready")
            return
        }
        let m = metrics
        let start = m.iconCenter(of: 0)
        let target = m.iconCenter(of: 4)
        pointerDown(at: start)
        pointerDragged(from: start, to: CGPoint(x: start.x + 10, y: start.y + 10))
        pointerDragged(from: start, to: target)
        debugLog("drag-demo active=\(drag?.tileID ?? "nil") merge=\(drag?.mergeTarget ?? "nil")")
    }

    /// Verifies wheel / trackpad paging without a human at the mouse. The
    /// assertions live in /tmp/launchos-debug.log:
    ///  - one physical wheel flick can arrive as several NSEvents a few ms
    ///    apart; the whole burst must advance at most one page,
    ///  - separate flicks (well apart in time) each advance one page,
    ///  - reversing direction steps back on the very first flick,
    ///  - no single trackpad gesture lands more than one page from its start.
    func runWheelProbe() {
        try? FileManager.default.removeItem(atPath: "/tmp/launchos-debug.log")
        debugLog("wheel-probe extent=\(pageExtent) pages=\(pageCount) wheelLines=\(settings.wheelLines)")

        let cases: [(String, CGScrollEventUnit, Int32)] = [
            ("line-3", .line, -3),
            ("pixel-16", .pixel, -16),
            ("pixel-24", .pixel, -24)
        ]
        func destPage() -> String {
            scrollEngine.destination
                .map { String(format: "%.0f", $0 / pageExtent) } ?? "none"
        }
        func emit(_ label: String, _ unit: CGScrollEventUnit, _ amount: Int32) {
            // wheel1 is the vertical axis in CGEvent's scroll-wheel API.
            guard let cg = CGEvent(scrollWheelEvent2Source: nil,
                                   units: unit,
                                   wheelCount: 2,
                                   wheel1: amount, wheel2: 0, wheel3: 0),
                  let event = NSEvent(cgEvent: cg) else { return }
            handleScroll(event)
            debugLog("\(label) precise=\(event.hasPreciseScrollingDeltas)"
                + " phase=\(event.phase.rawValue) dy=\(event.scrollingDeltaY)"
                + " destPage=\(destPage())")
        }

        // One physical flick, delivered as a burst of events with no gap.
        // With wheelLines > 1 a single flick must NOT turn a page at all.
        let burstExpected = settings.wheelLines > 1 ? "none" : "1"
        goToPage(0, animated: false)
        resetWheelNotchCount()
        for i in 1...4 { emit("burst notch=\(i)", .line, -3) }
        debugLog("BURST one-flick final=\(destPage()) expected=\(burstExpected)")

        // Well-separated flicks are independent: each one still turns a page.
        // Thread.sleep keeps the timestamps distinct without a run-loop hop.
        for (label, unit, amount) in cases {
            goToPage(0, animated: false)
            resetWheelNotchCount()
            for i in 1...4 {
                Thread.sleep(forTimeInterval: 0.16)
                emit("\(label) notch=\(i)", unit, amount)
            }
        }

        // Start on the last page; the first opposite notch must go back one.
        goToPage(pageCount - 1, animated: false)
        resetWheelNotchCount()
        Thread.sleep(forTimeInterval: 0.16)
        emit("reverse", .line, 3)

        // Precise (trackpad / Magic Mouse) path: a short but deliberate flick
        // never reaches half a page, yet it must still win one page. A tiny
        // nudge must stay on the current page. A long, fast swipe must not
        // stack the projected page on top of the travel bonus and jump two.
        // These settle through the real display link, so assertions are
        // written after the spring ends.
        goToPage(0, animated: false)
        scrollEngine.enqueue(30, phase: .began, momentumPhase: [])
        scrollEngine.enqueue(40, phase: .changed, momentumPhase: [])
        scrollEngine.enqueue(40, phase: .changed, momentumPhase: [])
        scrollEngine.enqueue(10, phase: .ended, momentumPhase: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            self.debugLog("flick travel=120 -> page=\(self.currentPage) pos=\(self.scrollPos)")
            self.goToPage(0, animated: false)
            self.scrollEngine.enqueue(20, phase: .began, momentumPhase: [])
            self.scrollEngine.enqueue(10, phase: .ended, momentumPhase: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                self.debugLog("nudge travel=30 -> page=\(self.currentPage) pos=\(self.scrollPos)")
                self.goToPage(0, animated: false)
                let big = self.pageExtent * 0.65
                self.scrollEngine.enqueue(big * 0.40, phase: .began, momentumPhase: [])
                self.scrollEngine.enqueue(big * 0.40, phase: .changed, momentumPhase: [])
                self.scrollEngine.enqueue(big * 0.20, phase: .ended, momentumPhase: [])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) {
                    self.debugLog("bigSwipe travel=\(Int(big)) -> page=\(self.currentPage)"
                        + " pos=\(Int(self.scrollPos)) expected<=1")
                    self.debugLog("WHEEL PROBE DONE")
                }
            }
        }
    }

    /// Verifies the layout snapshot round-trip and the folder drag-out path
    /// without touching the real state file. Run with both overrides:
    ///   LAUNCHOS_STATE_DIR=/tmp/… LAUNCHOS_SYNC_DIR=/tmp/… LaunchOS --layout-probe
    /// `LaunchOS --icloud-sync-probe` verifies the iCloud Drive hardening
    /// against an isolated LAUNCHOS_SYNC_DIR. Writes
    /// /tmp/launchos-icloud-sync.log and quits. Never touches real iCloud.
    func runICloudSyncProbe() {
        let logPath = "/tmp/launchos-icloud-sync.log"
        try? FileManager.default.removeItem(atPath: logPath)
        func note(_ text: String) {
            guard let data = (text + "\n").data(using: .utf8) else { return }
            let url = URL(fileURLWithPath: logPath)
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else { try? data.write(to: url) }
        }

        let ud = UserDefaults.standard
        let keys = ["launchos.sync.enabled", "launchos.sync.folderPath",
                    "launchos.sync.localUpdatedAt", "launchos.sync.lastPull"]
        let saved: [(String, Any?)] = keys.map { ($0, ud.object(forKey: $0)) }
        defer {
            LayoutSync.shared.setEnabled(false)
            for (k, v) in saved {
                if let v { ud.set(v, forKey: k) }
                else { ud.removeObject(forKey: k) }
            }
        }

        guard let dir = ProcessInfo.processInfo.environment["LAUNCHOS_SYNC_DIR"],
              !dir.isEmpty else {
            note("FAIL missing LAUNCHOS_SYNC_DIR")
            note("ICLOUD SYNC PROBE DONE")
            return
        }
        let fm = FileManager.default
        let real = URL(fileURLWithPath: dir).appendingPathComponent("LaunchOS-layout.json")
        let placeholder = URL(fileURLWithPath: dir)
            .appendingPathComponent(".LaunchOS-layout.json.icloud")
        try? fm.removeItem(at: real)
        try? fm.removeItem(at: placeholder)

        // A. clean coordinated push + status detection
        LayoutSync.shared.attach(model: self)
        LayoutSync.shared.setEnabled(true)
        LayoutSync.shared.pushNow(force: true)
        let a = LayoutSync.shared.probeRead()
        let dA = LayoutSync.shared.probeDiagnostics()
        note("A push fileExists=\(dA.fileExists) pages=\(a?.pages.count ?? -1)"
            + " cloudFolder=\(dA.cloudFolder) badge=\(dA.badge)")
        let aOK = dA.fileExists && (a?.pages.count ?? 0) > 0
            && !dA.cloudFolder && dA.badge.contains("自定义文件夹")

        // B. iCloud evicted the file: reconcile must NOT push a stale layout
        try? fm.moveItem(at: real, to: placeholder)
        LayoutSync.shared.probeReconcile()
        let dB = LayoutSync.shared.probeDiagnostics()
        note("B placeholder=\(dB.placeholder) realFileExists=\(dB.fileExists)"
            + " awaiting=\(dB.awaiting) status=\(LayoutSync.shared.status)")
        let bOK = dB.placeholder && !dB.fileExists && dB.awaiting
            && LayoutSync.shared.status.contains("正在从 iCloud 下载")

        // C. download lands: replay must keep the cloud snapshot readable
        try? fm.moveItem(at: placeholder, to: real)
        LayoutSync.shared.checkRemote()
        let dC = LayoutSync.shared.probeDiagnostics()
        let c = LayoutSync.shared.probeRead()
        note("C awaiting=\(dC.awaiting) fileExists=\(dC.fileExists)"
            + " pages=\(c?.pages.count ?? -1) status=\(LayoutSync.shared.status)")
        let cOK = !dC.awaiting && dC.fileExists && (c?.pages.count ?? 0) > 0

        // D. a newer snapshot from another Mac is still pulled
        var dOK = false
        if var remote = c, remote.pages.first?.count ?? 0 >= 3 {
            var first = remote.pages[0]
            first.swapAt(0, 2)
            remote.pages[0] = first
            remote.updatedAt = Date().addingTimeInterval(5)
            remote.deviceName = "Probe-Mac"
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            if let data = try? enc.encode(remote) {
                try? data.write(to: real, options: .atomic)
            }
            let expected = first.first?.id ?? "-"
            LayoutSync.shared.pullNow()
            let actual = pages.first?.first?.id ?? "-"
            dOK = expected == actual && actual != "-"
            note("D expected=\(expected) actual=\(actual)"
                + " status=\(LayoutSync.shared.status)")
        } else {
            note("D SKIP (not enough tiles on page 1)")
        }

        // E. default folder resolves to the real iCloud Drive path
        let def = LayoutSync.shared.probeDefaultFolderBadge()
        note("E defaultPath=\(def.path) ready=\(def.ready) badge=\(def.badge)")
        let eOK = def.path.contains("com~apple~CloudDocs") && !def.badge.isEmpty

        note("ASSERT A=\(aOK) B=\(bOK) C=\(cOK) D=\(dOK) E=\(eOK)")
        note("ICLOUD SYNC PROBE DONE")
    }

    func runLayoutProbe() {
        try? FileManager.default.removeItem(atPath: "/tmp/launchos-debug.log")
        let ud = UserDefaults.standard
        let keys = ["launchos.sync.enabled", "launchos.sync.folderPath",
                    "launchos.sync.localUpdatedAt", "launchos.sync.lastPull"]
        let saved: [(String, Any?)] = keys.map { ($0, ud.object(forKey: $0)) }

        goToPage(0, animated: false)
        pagerFrameInWindow = CGRect(x: 0, y: 0,
                                    width: areaSize.width, height: areaSize.height)

        // -- sync: push, read back, then apply a newer "other Mac" snapshot --
        LayoutSync.shared.attach(model: self)
        LayoutSync.shared.setEnabled(true)
        LayoutSync.shared.pushNow()
        let snapshot = LayoutSync.shared.probeRead()
        debugLog("layout-probe syncFile=\(snapshot != nil)"
            + " pages=\(snapshot?.pages.count ?? -1)"
            + " first=\(snapshot?.pages.first?.first?.id ?? "-")"
            + " localPages=\(pages.count)"
            + " localFirst=\(pages.first?.first?.id ?? "-")"
            + " wheelLines=\(settings.wheelLines)")

        if var remote = snapshot,
           let dir = ProcessInfo.processInfo.environment["LAUNCHOS_SYNC_DIR"],
           var firstPage = remote.pages.first,
           firstPage.count >= 3 {
            firstPage.swapAt(0, 2)
            remote.pages[0] = firstPage
            remote.updatedAt = Date().addingTimeInterval(5)
            remote.deviceName = "Probe-Mac"
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let url = URL(fileURLWithPath: dir).appendingPathComponent("LaunchOS-layout.json")
            if let data = try? encoder.encode(remote) {
                try? data.write(to: url, options: .atomic)
            }
            LayoutSync.shared.pullNow()
            debugLog("layout-probe pull expected=\(firstPage.first?.id ?? "-")"
                + " actual=\(pages.first?.first?.id ?? "-")"
                + " settingsKept=\(settings.wheelLines)")
        }

        // -- folder: two apps merge, one is dragged back onto the grid --
        let two = pages.flatMap { $0 }.filter { $0.bundleID != nil }.prefix(2)
        if two.count == 2,
           let a = two[0].bundleID, let b = two[1].bundleID {
            merge(a, into: b)
            if let folderTile = pages.flatMap({ $0 }).first(where: { $0.isFolder }) {
                let folderID = folderTile.id
                openFolderID = folderID
                let panel = CGRect(x: 100, y: 100, width: 400, height: 400)
                let outside = CGPoint(x: 900, y: 700)
                beginFolderDrag(appID: a, folderID: folderID,
                                at: CGPoint(x: 300, y: 300))
                updateFolderDrag(to: outside, panelFrame: panel)
                let dropped = endFolderDrag(at: outside, panelFrame: panel)
                debugLog("folder-drag-2 dropped=\(dropped)"
                    + " appBack=\(locate(a) != nil)"
                    + " dissolved=\(folder(folderID) == nil)"
                    + " survivorBack=\(locate(b) != nil)"
                    + " folderClosed=\(openFolderID == nil)")
            }
        }

        // -- folder: three apps, one dragged out, folder must survive --
        let three = pages.flatMap { $0 }.filter { $0.bundleID != nil }
            .prefix(3).compactMap { $0.bundleID }
        if three.count == 3 {
            merge(three[0], into: three[1])
            if let first = pages.flatMap({ $0 }).first(where: { $0.isFolder }) {
                merge(three[2], into: first.id)
            }
            if let ft = pages.flatMap({ $0 }).first(where: { $0.isFolder }),
               let ids = ft.folder?.bundleIDs, ids.count >= 3 {
                let folderID = ft.id
                openFolderID = folderID
                let panel = CGRect(x: 100, y: 100, width: 400, height: 400)
                let outside = CGPoint(x: 900, y: 700)
                beginFolderDrag(appID: ids[0], folderID: folderID,
                                at: CGPoint(x: 300, y: 300))
                updateFolderDrag(to: outside, panelFrame: panel)
                let dropped = endFolderDrag(at: outside, panelFrame: panel)
                debugLog("folder-drag-3 dropped=\(dropped)"
                    + " remaining=\(folder(folderID)?.bundleIDs.count ?? -1)"
                    + " appBack=\(locate(ids[0]) != nil)")
            }
        }

        // -- context menu "从文件夹移出" must also put the app back --
        if let ft = pages.flatMap({ $0 }).first(where: { $0.isFolder }),
           let first = ft.folder?.bundleIDs.first {
            removeFromFolder(appID: first, folderID: ft.id)
            debugLog("context-remove appBack=\(locate(first) != nil)")
        }

        LayoutSync.shared.setEnabled(false)
        for (key, value) in saved {
            if let value { ud.set(value, forKey: key) }
            else { ud.removeObject(forKey: key) }
        }
        debugLog("LAYOUT PROBE DONE")
    }

    /// `--layout-tools-probe`: verifies the manual layout tools without a
    /// human at the mouse. Pair with LAUNCHOS_STATE_DIR; never run it against
    /// the real state file.
    func runLayoutToolsProbe() {
        try? FileManager.default.removeItem(atPath: "/tmp/launchos-debug.log")
        if areaSize.width < 100 {
            updateArea(CGSize(width: 2508, height: 1233))
        }
        debugLog("layout-tools-probe area=\(areaSize) pages=\(pages.map { $0.count })")

        let originalPages = pages
        let originalHidden = hiddenTiles
        let originalManual = manualHidden
        let originalPinned = pinned
        let originalInsets = settings.gridInsets
        let originalLegacy = settings.gridInset

        // A: real file I/O round trip, then apply through the same path the
        // restore button uses.
        let backupURL = URL(fileURLWithPath: "/tmp/launchos-layout-tools-backup.json")
        let snapshot = LayoutBackup.snapshot(pages: pages,
                                             hidden: hiddenTiles,
                                             manualHidden: manualHidden,
                                             pinned: pinned)
        do {
            try LayoutBackup.write(snapshot, to: backupURL)
            let decoded = try LayoutBackup.read(from: backupURL)
            let pagesEqual = decoded.pages.map { $0.map(\.id) } == pages.map { $0.map(\.id) }
            let hiddenEqual = decoded.hidden.map(\.id) == hiddenTiles.map(\.id)
            let flagsEqual = decoded.manualHidden == Array(manualHidden).sorted()
                && decoded.pinned == Array(pinned).sorted()
            let bytes = (try? Data(contentsOf: backupURL))?.count ?? -1
            debugLog("A backup roundtrip=\(pagesEqual && hiddenEqual && flagsEqual) version=\(decoded.version) bytes=\(bytes)")
            let expectedFirst = originalPages.first?.first?.id ?? "-"
            applySyncedLayout(decoded)
            debugLog("A applied pages=\(pages.map { $0.count }) first=\(pages.first?.first?.id ?? "-") expected=\(expectedFirst)")
        } catch {
            debugLog("A FAIL error=\(error.localizedDescription)")
        }

        // B: a corrupt file and a foreign version must be rejected before
        // anything in the live model changes.
        let beforeBad = pages.map { $0.map(\.id) }
        let badURL = URL(fileURLWithPath: "/tmp/launchos-layout-tools-bad.json")
        try? "not json at all".write(to: badURL, atomically: true, encoding: .utf8)
        var badRejected = false
        do { _ = try LayoutBackup.read(from: badURL) } catch { badRejected = true }
        var foreign = snapshot
        foreign.version = 999
        let foreignURL = URL(fileURLWithPath: "/tmp/launchos-layout-tools-v999.json")
        try? LayoutBackup.encode(foreign).write(to: foreignURL)
        var versionRejected = false
        do { _ = try LayoutBackup.read(from: foreignURL) } catch { versionRejected = true }
        debugLog("B badRejected=\(badRejected) versionRejected=\(versionRejected) stateUnchanged=\(pages.map { $0.map(\.id) } == beforeBad)")

        // C: at both inset extremes the drawn icon centre must hit and the
        // inset band must stay blank. Regression guard for the GridMetrics
        // offset being applied to drawing but not to hit testing.
        func checkInset(_ label: String, _ value: Double) {
            settings.gridInsets = GridInsets.uniform(value)
            let m = metrics
            let hit = m.iconIndex(at: m.iconCenter(of: 2), count: 6)
            let band = CGPoint(x: max(1, m.insets.left / 2), y: max(1, m.insets.top / 2))
            let blank = m.iconIndex(at: band, count: 6)
            debugLog("C \(label) inset=\(Int(m.inset))pt cell=\(Int(m.cellW))x\(Int(m.cellH)) hit=\(hit.map(String.init) ?? "nil") band=\(blank.map(String.init) ?? "nil")")
        }
        checkInset("zero", Settings.gridInsetRange.lowerBound)
        checkInset("max", Settings.gridInsetRange.upperBound)
        settings.gridInsets = originalInsets
        settings.gridInset = originalLegacy

        // D: compact drops empty pages and preserves the flattened order.
        let flat = originalPages.flatMap { $0 }
        pages = [Array(flat.prefix(3)), [], Array(flat.dropFirst(3)), []]
        let beforeCompact = pages.count
        let result = compactPages()
        let noEmpty = pages.allSatisfy { !$0.isEmpty }
        let orderKept = pages.flatMap { $0 }.map(\.id) == flat.map(\.id)
        debugLog("D compact \(beforeCompact) -> \(result.after) noEmpty=\(noEmpty) orderKept=\(orderKept)")

        pages = originalPages
        hiddenTiles = originalHidden
        manualHidden = originalManual
        pinned = originalPinned
        settings.gridInsets = originalInsets
        settings.gridInset = originalLegacy
        debugLog("LAYOUT TOOLS PROBE DONE")
    }

    /// Diagnostic entry: `--edge-inset-probe`. Proves that top/bottom/left/
    /// right insets independently drive both drawing and hit testing, and
    /// that a state file with only the old `gridInset` key upgrades without
    /// changing the rendered grid. Writes /tmp/launchos-edge-inset.log.
    func runEdgeInsetProbe() {
        if areaSize.width < 100 { updateArea(CGSize(width: 2508, height: 1233)) }
        var lines: [String] = []
        let original = settings.gridInsets
        let originalLegacy = settings.gridInset
        func f(_ v: CGFloat) -> String { String(format: "%.2f", v) }
        func nearly(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.01 }

        // A. Old state compatibility: one value fans out to all four edges.
        let legacyValue = 0.07638524469339622
        let oldJSON = "{\"gridInset\":\(legacyValue)}".data(using: .utf8)!
        var legacyOK = false
        if let decoded = try? JSONDecoder().decode(Settings.self, from: oldJSON) {
            let e = decoded.gridInsets
            legacyOK = abs(e.top - legacyValue) < 1e-9
                && e.top == e.left && e.left == e.bottom && e.bottom == e.right
                && abs(decoded.gridInset - e.average) < 1e-9
            lines.append("A legacy gridInset=\(decoded.gridInset) "
                         + "top=\(e.top) left=\(e.left) bottom=\(e.bottom) right=\(e.right)")
        } else {
            lines.append("A FAIL decode")
        }

        // A2. Uniform fan-out must reproduce the legacy geometry exactly:
        // the old single-value code used size - 2*inset on both axes.
        settings.gridInsets = GridInsets.uniform(legacyValue)
        let upgraded = metrics
        let legacyPt = min(areaSize.width, areaSize.height) * CGFloat(legacyValue)
        let expectedW = (areaSize.width - legacyPt * 2) / CGFloat(max(3, settings.columns))
        let expectedH = (areaSize.height - legacyPt * 2) / CGFloat(max(2, settings.rows))
        let upgradeOK = nearly(upgraded.cellW, expectedW) && nearly(upgraded.cellH, expectedH)
        lines.append("A2 upgraded cellW=\(f(upgraded.cellW)) expected=\(f(expectedW)) "
                     + "cellH=\(f(upgraded.cellH)) expected=\(f(expectedH))")

        // `ox/oy` are the grid ORIGIN, not the tile centre: the centre also
        // moves when the cell shrinks, so it cannot distinguish top from
        // bottom (or left from right). centre - cell/2 recovers the origin.
        func snapshot() -> (cw: CGFloat, ch: CGFloat, ox: CGFloat, oy: CGFloat) {
            let m = metrics
            let c = m.center(of: 0)
            return (m.cellW, m.cellH, c.x - m.cellW / 2, c.y - m.cellH / 2)
        }
        func only(_ side: GridInsetSide, _ v: Double)
            -> (cw: CGFloat, ch: CGFloat, ox: CGFloat, oy: CGFloat) {
            var e = GridInsets()
            e.set(side, v)
            settings.gridInsets = e
            return snapshot()
        }

        settings.gridInsets = GridInsets()
        let base = snapshot()
        let hi = Settings.gridInsetRange.upperBound
        let top = only(.top, hi)
        let bottom = only(.bottom, hi)
        let left = only(.left, hi)
        let right = only(.right, hi)
        for (tag, s) in [("base", base), ("top", top), ("bottom", bottom),
                         ("left", left), ("right", right)] {
            lines.append("B \(tag) cellW=\(f(s.cw)) cellH=\(f(s.ch)) "
                         + "origin=\(f(s.ox)),\(f(s.oy))")
        }
        // top/left move the origin; bottom/right only shrink the far side.
        let topOK = top.ch < base.ch - 1 && top.oy > base.oy + 1
            && nearly(top.cw, base.cw) && nearly(top.ox, base.ox)
        let bottomOK = bottom.ch < base.ch - 1 && nearly(bottom.oy, base.oy)
            && nearly(bottom.cw, base.cw) && nearly(top.ch, bottom.ch)
        let leftOK = left.cw < base.cw - 1 && left.ox > base.ox + 1
            && nearly(left.ch, base.ch) && nearly(left.oy, base.oy)
        let rightOK = right.cw < base.cw - 1 && nearly(right.ox, base.ox)
            && nearly(right.ch, base.ch) && nearly(left.cw, right.cw)

        // C. Four asymmetric edges: hit testing and bounds must follow drawing.
        var e = GridInsets()
        e.set(.top, 0.12); e.set(.left, 0.09)
        e.set(.bottom, 0.06); e.set(.right, 0.15)
        settings.gridInsets = e
        let m = metrics
        let hit = m.iconIndex(at: m.iconCenter(of: 2), count: 6)
        let inside = m.contains(CGPoint(x: m.insets.left + 1, y: m.insets.top + 1))
        let outsideRight = m.contains(CGPoint(x: m.size.width - m.insets.right + 1,
                                              y: m.insets.top + 1))
        let outsideBottom = m.contains(CGPoint(x: m.insets.left + 1,
                                               y: m.size.height - m.insets.bottom + 1))
        let blankTop = m.iconIndex(at: CGPoint(x: m.insets.left + 1,
                                               y: max(1, m.insets.top / 2)), count: 6)
        lines.append("C hit=\(hit.map(String.init) ?? "nil") inside=\(inside) "
                     + "outsideRight=\(outsideRight) outsideBottom=\(outsideBottom) "
                     + "blankTop=\(blankTop.map(String.init) ?? "nil")")
        let hitOK = hit == 2 && inside && !outsideRight && !outsideBottom && blankTop == nil

        // D. Persist round trip keeps all four edges and the legacy mirror.
        var roundtripOK = false
        if let data = try? JSONEncoder().encode(settings),
           let restored = try? JSONDecoder().decode(Settings.self, from: data) {
            roundtripOK = restored.gridInsets == e
                && abs(restored.gridInset - e.average) < 1e-9
            lines.append("D restored top=\(restored.gridInsets.top) left=\(restored.gridInsets.left) "
                         + "bottom=\(restored.gridInsets.bottom) right=\(restored.gridInsets.right) "
                         + "legacy=\(restored.gridInset)")
        } else {
            lines.append("D FAIL encode/decode")
        }

        settings.gridInsets = original
        settings.gridInset = originalLegacy
        let ok = legacyOK && upgradeOK && topOK && bottomOK && leftOK
                 && rightOK && hitOK && roundtripOK
        lines.append("ASSERT legacy=\(legacyOK) upgrade=\(upgradeOK) top=\(topOK) bottom=\(bottomOK) "
                     + "left=\(leftOK) right=\(rightOK) hitAndBounds=\(hitOK) "
                     + "roundtrip=\(roundtripOK)")
        lines.append(ok ? "PASS" : "FAIL")
        lines.append("DONE")
        try? (lines.joined(separator: "\n") + "\n")
            .write(toFile: "/tmp/launchos-edge-inset.log", atomically: true, encoding: .utf8)
    }

    /// Queues a debounced state edit immediately before the launcher hides.
    /// The real exit path must flush it synchronously, so an external check
    /// of state.json after the process is gone proves no write was lost.
    func runQuitProbe() {
        debugLog("QUIT PROBE START quitOnHide=\(settings.quitOnHide) "
                 + "residencyVersion=\(settings.residencyChoiceVersion) "
                 + "exitDecision=\(ResidencyPolicy.shouldExitOnHide(settings: settings, diagnosticMode: true, quitProbe: true))")
        var record = Usage(launches: 4242)
        record.lastLaunch = Date()
        usage["__quit_probe__"] = record
        persist()
        debugLog("sentinel queued launches=4242 (debounced, not flushed)")
    }

    /// Exercises folder-merge hit testing and the exact grid cell an app lands
    /// on when dragged out of an open folder. Each case restores the starting
    /// layout, so cases are independent. Only reachable via `--merge-probe`
    /// and must be run with LAUNCHOS_STATE_DIR pointed at an isolated state.
    func runMergeProbe() {
        try? FileManager.default.removeItem(atPath: "/tmp/launchos-debug.log")
        let m = metrics
        let original = pages
        pagerFrameInWindow = CGRect(x: 0, y: 0,
                                    width: areaSize.width, height: areaSize.height)
        debugLog("merge-probe area=\(areaSize) capacity=\(m.capacity)"
            + " pages=\(pages.map { $0.count })")

        func restore() {
            pages = original
            openFolderID = nil
        }

        /// Drag one icon's centre onto another icon's centre through the real
        /// pointer pipeline, then report whether a merge was armed and whether
        /// a two-member folder was actually created on release.
        func attempt(_ label: String, from: Int, to: Int) {
            restore()
            guard pages[0].count > max(from, to) else { return }
            let targetID = pages[0][to].id
            let start = m.iconCenter(of: from)
            let end = m.iconCenter(of: to)
            pointerDown(at: start)
            pointerDragged(from: start, to: CGPoint(x: start.x + 12, y: start.y + 12))
            for step in 1...10 {
                let t = CGFloat(step) / 10
                pointerDragged(from: start,
                               to: CGPoint(x: start.x + (end.x - start.x) * t,
                                           y: start.y + (end.y - start.y) * t))
            }
            let armed = drag?.mergeTarget
            pointerUp(at: end)
            let folders = pages[0].filter { $0.isFolder }
            debugLog("\(label) armed=\(armed == targetID)"
                + " expected=\(targetID) folder=\(folders.count)"
                + " members=\(folders.first?.folder?.bundleIDs.count ?? -1)")
        }

        attempt("A 0->1", from: 0, to: 1)
        attempt("B 1->0", from: 1, to: 0)
        attempt("C 0->10", from: 0, to: 10)
        attempt("D 5->6", from: 5, to: 6)

        // Drop-out: a 3-app folder keeps its shape when one app leaves, so
        // the only grid change should be an insertion at `slot` and every
        // later tile shifting by one.
        restore()
        let ids = original[0].prefix(3).compactMap { $0.bundleID }
        if ids.count == 3 {
            merge(ids[0], into: ids[1])
            if let folderID = pages[0].first(where: { $0.isFolder })?.id {
                merge(ids[2], into: folderID)
            }
            if let folderID = pages[0].first(where: { $0.isFolder })?.id {
                let before = pages[0]
                let slot = 5
                let drop = containerPoint(m.iconCenter(of: slot), page: 0)
                let panel = CGRect(x: -100, y: -100, width: 10, height: 10)
                openFolderID = folderID
                beginFolderDrag(appID: ids[0], folderID: folderID, at: .zero)
                updateFolderDrag(to: drop, panelFrame: panel)
                let dropped = endFolderDrag(at: drop, panelFrame: panel)
                let landed = pages[0].firstIndex(where: { $0.bundleID == ids[0] }) ?? -1
                let shifted = before.count > slot && pages[0].count > slot + 1
                    && before[slot].id == pages[0][slot + 1].id
                debugLog("E dropOut dropped=\(dropped) wantedSlot=\(slot)"
                    + " landed=\(landed) shifted=\(shifted)"
                    + " counts=\(pages.map { $0.count })")
            }
        }
        // F: the real user layout has a FULL first page. A folder on that page
        // still occupies one cell, so dragging an app out must shift the
        // tiles after the drop slot and cascade the last one to the next page.
        restore()
        let threeFull = original[0].prefix(3).compactMap { $0.bundleID }
        if threeFull.count == 3 {
            var p0 = Array(original[0])
            var p1 = original.indices.contains(1) ? Array(original[1]) : []
            p0.removeFirst(3)
            p0.insert(Tile.makeFolder(Folder(name: "探针", bundleIDs: threeFull)), at: 0)
            while p0.count < m.capacity, !p1.isEmpty { p0.append(p1.removeFirst()) }
            pages[0] = p0
            if original.indices.contains(1) { pages[1] = p1 }
            if let folderID = pages[0].first(where: { $0.isFolder })?.id {
                let before = pages[0]
                let slot = 5
                let drop = containerPoint(m.iconCenter(of: slot), page: 0)
                let panel = CGRect(x: -100, y: -100, width: 10, height: 10)
                openFolderID = folderID
                beginFolderDrag(appID: threeFull[0], folderID: folderID, at: .zero)
                updateFolderDrag(to: drop, panelFrame: panel)
                let dropped = endFolderDrag(at: drop, panelFrame: panel)
                let landed = pages[0].firstIndex(where: { $0.bundleID == threeFull[0] }) ?? -1
                let shifted = before.count > slot && pages[0].count > slot + 1
                    && before[slot].id == pages[0][slot + 1].id
                debugLog("F fullPage dropped=\(dropped) wantedSlot=\(slot)"
                    + " landed=\(landed) shifted=\(shifted)"
                    + " counts=\(pages.map { $0.count })")
            }
        }
        // G: dropping an app onto an existing folder must add it, not create
        // a second folder.
        restore()
        let pair = original[0].prefix(2).compactMap { $0.bundleID }
        if pair.count == 2 {
            merge(pair[0], into: pair[1])
            if let folderSlot = pages[0].firstIndex(where: { $0.isFolder }),
               let joining = pages[0].first(where: { $0.bundleID != nil })?.bundleID,
               let from = pages[0].firstIndex(where: { $0.bundleID == joining }) {
                let start = m.iconCenter(of: from)
                let end = m.iconCenter(of: folderSlot)
                pointerDown(at: start)
                pointerDragged(from: start, to: CGPoint(x: start.x + 12, y: start.y + 12))
                for step in 1...10 {
                    let t = CGFloat(step) / 10
                    pointerDragged(from: start,
                                   to: CGPoint(x: start.x + (end.x - start.x) * t,
                                               y: start.y + (end.y - start.y) * t))
                }
                pointerUp(at: end)
                let folders = pages[0].filter { $0.isFolder }
                debugLog("G intoFolder folders=\(folders.count)"
                    + " members=\(folders.first?.folder?.bundleIDs.count ?? -1)"
                    + " contains=\(folders.first?.folder?.bundleIDs.contains(joining) ?? false)")
            }
        }

        // H: with the grid frozen during the drag, a release over empty grid
        // space must still reorder — just once, at the end.
        restore()
        if original[0].count >= 4 {
            pages[0] = Array(original[0].prefix(4))
            let movingID = pages[0][0].id
            let start = m.iconCenter(of: 0)
            let end = m.iconCenter(of: 5)
            pointerDown(at: start)
            pointerDragged(from: start, to: CGPoint(x: start.x + 12, y: start.y + 12))
            for step in 1...10 {
                let t = CGFloat(step) / 10
                pointerDragged(from: start,
                               to: CGPoint(x: start.x + (end.x - start.x) * t,
                                           y: start.y + (end.y - start.y) * t))
            }
            let armed = drag?.mergeTarget
            pointerUp(at: end)
            let landed = pages[0].firstIndex(where: { $0.id == movingID }) ?? -1
            debugLog("H reorder armed=\(armed ?? "-") start=0 landed=\(landed)"
                + " count=\(pages[0].count)")
        }
        debugLog("MERGE PROBE DONE")
    }
}
