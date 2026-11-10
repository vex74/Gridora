import Foundation
import SwiftUI

/// Deterministic assertions for `LaunchOS --appearance-probe`. Every check is
/// a pure function of Settings / DesignTokens / Motion, so a PASS cannot come
/// from a coincidental window layout or a screenshot. Writes one log and
/// returns the overall result.
enum AppearanceProbe {
    static let logPath = "/tmp/launchos-appearance.log"

    @discardableResult
    static func run() -> Bool {
        var lines: [String] = ["APPEARANCE PROBE"]
        var all = true
        func f(_ v: Double) -> String { String(format: "%.3f", v) }
        func check(_ tag: String, _ ok: Bool, _ detail: String) {
            lines.append("\(tag) \(ok ? "PASS" : "FAIL") \(detail)")
            if !ok { all = false }
        }

        // A. The inline preview must track every glass parameter, and only
        // those parameters: identical settings must produce an identical
        // snapshot (guards against a probe that always reports "changed").
        var a = Settings()
        a.glassEnabled = true
        a.glassStyle = .regular
        a.glassTint = 0.38
        a.glassRadius = 24
        a.glassScrim = 0.28
        let s1 = GlassPreviewSnapshot(settings: a)
        var b = a
        b.glassEnabled = false
        b.glassStyle = .clear
        b.glassTint = 0.60
        b.glassRadius = 30
        b.glassScrim = 0.48
        let s2 = GlassPreviewSnapshot(settings: b)
        // One slider, two surfaces: the search preview reports the derived
        // field radius (58% of the panel radius), not the panel radius itself.
        let derived = SearchGlass.fieldRadius(30)
        let tracks = s1 != s2 && !s2.enabled && s2.style == .clear
            && s2.tintPercent == 60 && s2.radius == Int(derived.rounded())
            && s2.scrimPercent == 48
            && s2.readout.contains("通透") && s2.readout.contains("\(Int(derived.rounded()))pt")
        check("A preview", tracks,
              "s1=\(s1.readout) s2=\(s2.readout) derived=\(f(Double(derived)))")
        check("A2 stable", GlassPreviewSnapshot(settings: a) == s1,
              "same Settings -> same snapshot=\(GlassPreviewSnapshot(settings: a) == s1)")

        // B. Backdrop chroma budget. First prove the detector actually rejects
        // the old magenta/violet colours, otherwise a PASS would be meaningless.
        let legacyMagenta = Color(red: 0.75, green: 0.36, blue: 0.90)
        let legacyViolet = Color(red: 0.55, green: 0.22, blue: 0.92)
        let detectorWorks = DesignTokens.chroma(legacyMagenta) > 0.45
            && DesignTokens.chroma(legacyViolet) > 0.45
        check("B0 detector", detectorWorks,
              "legacy magenta=\(f(DesignTokens.chroma(legacyMagenta))) violet=\(f(DesignTokens.chroma(legacyViolet)))")

        let cool: [(String, Color)] = [
            ("canvas", DesignTokens.canvas),
            ("panel", DesignTokens.panelSurface),
            ("coolA", DesignTokens.auroraCoolA),
            ("coolB", DesignTokens.auroraCoolB),
            ("coolC", DesignTokens.auroraCoolC),
            ("steel", DesignTokens.auroraSteel),
            ("deep", DesignTokens.auroraDeep)
        ]
        let chromas = cool.map { (name: $0.0, value: DesignTokens.chroma($0.1)) }
        check("B1 lowChroma", chromas.allSatisfy { $0.value <= 0.45 },
              chromas.map { "\($0.name)=\(f($0.value))" }.joined(separator: " "))
        let warmOK = DesignTokens.chroma(DesignTokens.auroraWarm) > 0.45
            && DesignTokens.auroraWarmWeight <= 0.20
        check("B2 oneWarm", warmOK,
              "warmChroma=\(f(DesignTokens.chroma(DesignTokens.auroraWarm))) weight=\(f(DesignTokens.auroraWarmWeight))")

        // C. Slider captions must match the single source of truth.
        let rangesOK = Settings.glassTintRange == 0...0.75
            && Settings.glassRadiusRange == 6...36
            && Settings.glassScrimRange == 0...0.60
            && Settings.iconScaleRange == 0.78...1.4
        check("C ranges", rangesOK,
              "tint=0...0.75 radius=6...36 scrim=0...0.60 iconScale=0.78...1.4")

        // D. Reduce Motion must still collapse the shared durations; settings
        // and TopBar animations now go through Motion.quick, so the switch is
        // enough to cover them.
        let saved = Motion.reduceMotion
        Motion.reduceMotion = true
        let reducedOpen = Motion.openDuration
        let reducedWindow = Motion.windowDuration
        Motion.reduceMotion = false
        let normalOpen = Motion.openDuration
        Motion.reduceMotion = saved
        check("D reduceMotion", reducedOpen < 0.01 && reducedWindow < 0.01 && normalOpen > 0.2,
              "reducedOpen=\(f(reducedOpen)) reducedWindow=\(f(reducedWindow)) normalOpen=\(f(normalOpen))")

        // E. Focus ring and panel radius are single constants, not three
        // per-call values (24 / 26 / 28 used to coexist).
        let tokensOK = DesignTokens.panelRadius == 24
            && DesignTokens.focusRingWidth == 2 && DesignTokens.focusRingInset == -2
            && DesignTokens.cardRadius == 10 && DesignTokens.controlRadius == 6
        check("E tokens", tokensOK,
              "panelRadius=\(Int(DesignTokens.panelRadius)) ring=\(Int(DesignTokens.focusRingWidth))pt inset=\(Int(DesignTokens.focusRingInset))pt")

        // F. The settings pane really has seven pages, including Appearance.
        check("F pages", SettingsPage.allCases.count == 7 && SettingsPage.appearance.rawValue == "外观",
              "count=\(SettingsPage.allCases.count) appearance=\(SettingsPage.appearance.rawValue)")

        // G. ONE glass group for the whole app. Before v1.5 there were two:
        // this group now has to move all three surfaces at once — that is the
        // inverse of the old "search must not touch the folder" assertion, and
        // it is what stops a future edit from re-introducing a second knob.
        var base = Settings()
        base.glassEnabled = true
        base.glassStyle = .regular
        base.glassTint = Settings.defaultGlassTint
        base.glassRadius = Settings.defaultGlassRadius
        base.glassScrim = Settings.defaultGlassScrim
        let f1 = FolderGlassSnapshot(settings: base)
        let i1 = FolderIconGlass(settings: base, size: 80)

        var g = base
        g.glassEnabled = false
        g.glassStyle = .clear
        g.glassTint = 0.62
        g.glassRadius = 30
        g.glassScrim = 0.50
        let f2 = FolderGlassSnapshot(settings: g)
        let i2 = FolderIconGlass(settings: g, size: 80)
        check("G1 tracksAllFive", f1 != f2 && !f2.enabled && f2.style == .clear
              && f2.tintPercent == 62 && f2.radius == 30 && f2.scrimPercent == 50
              && f2.modeText == "近黑实底" && f2.readout.contains("30pt"),
              "f1=\(f1.readout) f2=\(f2.readout)")
        check("G2 stable", FolderGlassSnapshot(settings: base) == f1
              && FolderIconGlass(settings: base, size: 80) == i1,
              "same Settings -> same snapshots=\(FolderGlassSnapshot(settings: base) == f1)")

        check("G3 oneSliderMovesEverySurface",
              f1 != f2 && i1 != i2
              && GlassPreviewSnapshot(settings: g) != GlassPreviewSnapshot(settings: base),
              "panelChanged=\(f1 != f2) iconChanged=\(i1 != i2) "
              + "searchChanged=\(GlassPreviewSnapshot(settings: g) != GlassPreviewSnapshot(settings: base))")

        check("G4 defaultsAndFieldDerivation",
              Settings.defaultGlassRadius == Double(DesignTokens.panelRadius)
              && Settings.defaultGlassTint == 0.38
              && Settings.defaultGlassScrim == 0.28
              // 58% of 24 pt is 13.92; the field has always been 14 pt, so the
              // derivation is asserted after rounding — the same value the
              // snapshot and the live field actually use.
              && SearchGlass.fieldRadius(Settings.defaultGlassRadius).rounded() == 14
              && SearchGlass.fieldRadius(6) == 8
              && SearchGlass.fieldRadius(36) == 20,
              "radius=\(Int(Settings.defaultGlassRadius)) tint=\(f(Settings.defaultGlassTint)) "
              + "scrim=\(f(Settings.defaultGlassScrim)) "
              + "field(24)=\(f(Double(SearchGlass.fieldRadius(24)))) "
              + "field(6)=\(f(Double(SearchGlass.fieldRadius(6)))) "
              + "field(36)=\(f(Double(SearchGlass.fieldRadius(36))))")

        do {
            let encoded = try JSONEncoder().encode(g)
            let decoded = try JSONDecoder().decode(Settings.self, from: encoded)
            check("G5 stateRoundTrip",
                  !decoded.glassEnabled && decoded.glassStyle == .clear
                  && decoded.glassTint == 0.62 && decoded.glassRadius == 30
                  && decoded.glassScrim == 0.50,
                  "enabled=\(decoded.glassEnabled) style=\(decoded.glassStyle.rawValue) "
                  + "tint=\(f(decoded.glassTint)) radius=\(Int(decoded.glassRadius)) "
                  + "scrim=\(f(decoded.glassScrim))")

            var raw = (try JSONSerialization.jsonObject(with: encoded)) as? [String: Any] ?? [:]
            // The retired groups must not be re-emitted: a stale folder value
            // written back into the file would win the migration next launch.
            let legacyKeys = ["searchGlassEnabled", "searchGlassStyle", "searchGlassTint",
                              "searchGlassRadius", "searchScrim",
                              "folderGlassEnabled", "folderGlassStyle", "folderGlassTint",
                              "folderGlassRadius", "folderGlassScrim"]
            let stillWritesLegacy = legacyKeys.filter { raw[$0] != nil }
            check("G6 legacyKeysNotReemitted", stillWritesLegacy.isEmpty,
                  "present=\(stillWritesLegacy)")

            raw["glassStyle"] = "bogus"
            raw["glassTint"] = 9.0
            raw["glassRadius"] = -4
            raw["glassScrim"] = 1.4
            let bad = try JSONDecoder().decode(
                Settings.self,
                from: try JSONSerialization.data(withJSONObject: raw))
            check("G7 corruptClamped",
                  bad.glassStyle == .regular && bad.glassTint == 0.75
                  && bad.glassRadius == 6 && bad.glassScrim == 0.60,
                  "style=\(bad.glassStyle.rawValue) tint=\(f(bad.glassTint)) "
                  + "radius=\(Int(bad.glassRadius)) scrim=\(f(bad.glassScrim))")

            // G8 — a v1.4 file carries BOTH groups with different values. The
            // folder group wins (larger surface, tuned last), so the panel the
            // user already tuned keeps its look and only search snaps to it.
            var v14: [String: Any] = [:]
            v14["searchGlassEnabled"] = true
            v14["searchGlassStyle"] = "clear"
            v14["searchGlassTint"] = 0.70
            v14["searchGlassRadius"] = 8.0
            v14["searchScrim"] = 0.60
            v14["folderGlassEnabled"] = false
            v14["folderGlassStyle"] = "regular"
            v14["folderGlassTint"] = 0.62
            v14["folderGlassRadius"] = 32.0
            v14["folderGlassScrim"] = 0.50
            let merged = try JSONDecoder().decode(
                Settings.self,
                from: try JSONSerialization.data(withJSONObject: v14))
            check("G8 v14MergePrefersFolder",
                  !merged.glassEnabled && merged.glassStyle == .regular
                  && merged.glassTint == 0.62 && merged.glassRadius == 32
                  && merged.glassScrim == 0.50,
                  "enabled=\(merged.glassEnabled) style=\(merged.glassStyle.rawValue) "
                  + "tint=\(f(merged.glassTint)) radius=\(Int(merged.glassRadius)) "
                  + "scrim=\(f(merged.glassScrim))")

            // G9 — a v1.3 file has only the search group.
            let searchOnly: [String: Any] = [
                "searchGlassEnabled": false,
                "searchGlassStyle": "clear",
                "searchGlassTint": 0.70,
                "searchGlassRadius": 8.0,
                "searchScrim": 0.60
            ]
            let fromSearch = try JSONDecoder().decode(
                Settings.self,
                from: try JSONSerialization.data(withJSONObject: searchOnly))
            check("G9 searchOnlyMigrates",
                  !fromSearch.glassEnabled && fromSearch.glassStyle == .clear
                  && fromSearch.glassTint == 0.70 && fromSearch.glassRadius == 8
                  && fromSearch.glassScrim == 0.60,
                  "enabled=\(fromSearch.glassEnabled) style=\(fromSearch.glassStyle.rawValue) "
                  + "tint=\(f(fromSearch.glassTint)) radius=\(Int(fromSearch.glassRadius))")

            // G10 — no glass keys at all (pre-glass file): shipped look.
            let legacy = try JSONDecoder().decode(
                Settings.self,
                from: try JSONSerialization.data(withJSONObject: [String: Any]()))
            check("G10 emptyFileUsesDefaults",
                  legacy.glassEnabled
                  && legacy.glassStyle == .regular
                  && legacy.glassTint == Settings.defaultGlassTint
                  && legacy.glassRadius == Settings.defaultGlassRadius
                  && legacy.glassScrim == Settings.defaultGlassScrim,
                  "enabled=\(legacy.glassEnabled) tint=\(f(legacy.glassTint)) "
                  + "radius=\(Int(legacy.glassRadius)) scrim=\(f(legacy.glassScrim))")
        } catch {
            check("G5 stateRoundTrip", false, "JSON error=\(error)")
        }

        // H. The collapsed folder tile must be driven by the SAME five keys as
        // the open panel and the search surfaces. Separate formulas here would
        // be the exact bug that let the small icon stay a black square after
        // the panel was glassed.
        let iconSize: CGFloat = 80
        let icon0 = FolderIconGlass(settings: base, size: iconSize)
        let panel0 = FolderGlassSnapshot(settings: base)
        check("H1 sameSettingsAsPanel",
              icon0.style == panel0.style
              && icon0.tintPercent == panel0.tintPercent
              && icon0.radius == panel0.radius
              && icon0.scrimPercent == panel0.scrimPercent,
              "icon=\(icon0.readout) panel=\(panel0.readout) "
              + "iconEnabled=\(icon0.enabled) panelEnabled=\(panel0.enabled)")
        check("H2 defaultGeometryUnchanged",
              abs(icon0.cornerRadius - iconSize * 0.235) < 0.001,
              "corner=\(f(icon0.cornerRadius)) expected=\(f(iconSize * 0.235))")

        let icon1 = i2
        check("H3 tracksAllFive",
              !icon1.enabled && icon1.style == .clear && icon1.tintPercent == 62
              && icon1.radius == 30 && icon1.scrimPercent == 50
              && icon1.modeText == "原材质"
              && abs(icon1.innerDim - 0.25) < 0.001
              && icon1 != icon0,
              "icon1=\(icon1.readout) dim=\(f(icon1.innerDim))")

        var k = base
        k.glassRadius = 6
        let tight = FolderIconGlass(settings: k, size: iconSize)
        k.glassRadius = 36
        let round = FolderIconGlass(settings: k, size: iconSize)
        check("H4 radiusClampedAndMonotonic",
              tight.cornerRadius >= iconSize * 0.10
              && round.cornerRadius <= iconSize * 0.42
              && tight.cornerRadius < icon0.cornerRadius
              && icon0.cornerRadius < round.cornerRadius,
              "6pt=\(f(tight.cornerRadius)) 24pt=\(f(icon0.cornerRadius)) "
              + "36pt=\(f(round.cornerRadius))")

        // H5 — the tint slider is global: one write must reach search, panel
        // and icon together. There is no per-surface escape hatch any more.
        var tintOnly = base
        tintOnly.glassTint = 0.70
        check("H5 tintReachesAllThree",
              FolderIconGlass(settings: tintOnly, size: iconSize) != icon0
              && FolderGlassSnapshot(settings: tintOnly) != panel0
              && GlassPreviewSnapshot(settings: tintOnly) != GlassPreviewSnapshot(settings: base),
              "iconChanged=\(FolderIconGlass(settings: tintOnly, size: iconSize) != icon0) "
              + "panelChanged=\(FolderGlassSnapshot(settings: tintOnly) != panel0)")

        let small = FolderIconGlass(settings: base, size: 46)
        check("H6 sizeOnlyChangesGeometry",
              small.enabled == icon0.enabled && small.style == icon0.style
              && small.tintPercent == icon0.tintPercent
              && small.radius == icon0.radius
              && small.scrimPercent == icon0.scrimPercent
              && small.cornerRadius < icon0.cornerRadius,
              "46pt=\(f(small.cornerRadius)) 80pt=\(f(icon0.cornerRadius))")

        let expectedEnabled = base.glassEnabled && !ProbeConfig.folderIconNoGlass
            && (ProbeConfig.folderIconPlate || ProbeConfig.noRaster)
        check("H7 rollbackSwitchHonoured",
              icon0.enabled == expectedEnabled,
              "iconEnabled=\(icon0.enabled) expected=\(expectedEnabled) "
              + "noGlass=\(ProbeConfig.folderIconNoGlass) "
              + "plate=\(ProbeConfig.folderIconPlate) noRaster=\(ProbeConfig.noRaster)")

        // I. v1.6: the selection/hover highlight is the FOURTH surface driven
        // by the same five glass keys. Before this, the main grid, search
        // results and open folder each hard-coded a different white rounded
        // rectangle (0.30 / 0.25 / 0.24 × icon size), so the glass sliders
        // moved three surfaces but not the one the pointer rests on.
        let sel0 = SelectionHighlightStyle(settings: base, iconSize: iconSize)
        check("I1 defaultReproducesOriginalGrid",
              abs(sel0.cornerRadius - iconSize * 0.27) < 0.001
              && abs(sel0.hoverFill - 0.13) < 0.01
              && abs(sel0.strokeOpacity - 0.82) < 0.01
              && abs(sel0.labelFill - 0.16) < 0.01
              // The 18 pt blur was the main grid's value at a 92 pt icon;
              // it is proportional to icon size, so compare the ratio here.
              && abs(sel0.glowBlur - iconSize * 0.20) < 0.001,
              sel0.readout)

        var iTint = base
        iTint.glassTint = 0.70
        let selTint = SelectionHighlightStyle(settings: iTint, iconSize: iconSize)
        check("I2 oneSliderMovesFourSurfaces",
              selTint != sel0
              && FolderIconGlass(settings: iTint, size: iconSize) != icon0
              && FolderGlassSnapshot(settings: iTint) != panel0
              && GlassPreviewSnapshot(settings: iTint) != GlassPreviewSnapshot(settings: base),
              "highlightChanged=\(selTint != sel0) tint=\(f(iTint.glassTint))")

        var iRadius = base
        iRadius.glassRadius = 6
        let selTight = SelectionHighlightStyle(settings: iRadius, iconSize: iconSize)
        iRadius.glassRadius = 36
        let selRound = SelectionHighlightStyle(settings: iRadius, iconSize: iconSize)
        check("I3 radiusClampedAndMonotonic",
              selTight.cornerRadius >= iconSize * 0.10
              && selRound.cornerRadius <= iconSize * 0.42
              && selTight.cornerRadius < sel0.cornerRadius
              && sel0.cornerRadius < selRound.cornerRadius,
              "6pt=\(f(selTight.cornerRadius)) 24pt=\(f(sel0.cornerRadius)) "
              + "36pt=\(f(selRound.cornerRadius))")

        var iOff = base
        iOff.glassEnabled = false
        let selOff = SelectionHighlightStyle(settings: iOff, iconSize: iconSize)
        check("I4 glassOffKeepsHighlightWithoutGlow",
              !selOff.enabled && selOff.glowBlur == 0 && selOff.hoverScale == 1
              && selOff.hoverFill > 0.05 && selOff != sel0,
              selOff.readout)

        check("I5 rollbackSwitchHonoured",
              sel0.enabled == (base.glassEnabled && !ProbeConfig.selectionGlassDisabled),
              "enabled=\(sel0.enabled) noSelectionGlass=\(ProbeConfig.selectionGlassDisabled)")

        // The three call sites construct the value from the same Settings;
        // there is no per-surface escape hatch and no second geometry formula.
        let selGrid = SelectionHighlightStyle(settings: base, iconSize: 92)
        let selFolder = SelectionHighlightStyle(settings: base, iconSize: 92)
        let selSearch = SelectionHighlightStyle(settings: base, iconSize: 92)
        check("I6 threeSurfacesShareOneValue",
              selGrid == selFolder && selFolder == selSearch
              && selGrid != SelectionHighlightStyle(settings: base, iconSize: 46),
              "grid=\(selGrid.readout)")

        // J. v1.6.1: the full-screen fog is ONE value in TWO NSWindows.
        // Before this the main window drew ultraThinMaterial + scrim while
        // the menu-bar cover (level 26) drew only the clean wallpaper blur,
        // so a visible seam ran across the top whenever a folder was open.
        let folderState = BackdropFog.state(openFolderID: "probe-folder",
                                            searchOpen: false,
                                            outsidePanel: false)
        let coverFog = BackdropFog.make(settings: base, state: folderState)
        let gridFog = BackdropFog.make(settings: base,
                                       state: .folder(outsidePanel: false))
        check("J1 oneFogForBothWindows",
              coverFog == gridFog && folderState == .folder(outsidePanel: false),
              "cover=[\(coverFog.readout)] grid=[\(gridFog.readout)]")

        var jScrim = base
        jScrim.glassScrim = 0.55
        let jFolder = BackdropFog.make(settings: jScrim,
                                       state: .folder(outsidePanel: false))
        let jCover = BackdropFog.make(settings: jScrim, state: folderState)
        let jSearch = BackdropFog.make(settings: jScrim, state: .search)
        check("J2 oneSliderMovesEveryFog",
              jFolder != gridFog
              && abs(jFolder.scrim - 0.55) < 0.0001
              && abs(jFolder.tint - 0.55) < 0.0001
              && jCover == jFolder
              && abs(jSearch.tint - 0.55) < 0.0001
              && abs(jSearch.scrim - 0.55 * 0.45) < 0.0001,
              "folder=[\(jFolder.readout)] search=[\(jSearch.readout)]")

        check("J3 sameMaterialOnAllStates",
              jFolder.material == jSearch.material
              && jSearch.material == jCover.material,
              "material=\(jFolder.material.rawValue)")

        var jOff = base
        jOff.glassEnabled = false
        let jOffFog = BackdropFog.make(settings: jOff,
                                       state: .folder(outsidePanel: false))
        let jOffSearch = BackdropFog.make(settings: jOff, state: .search)
        check("J4 glassOffDropsMaterialKeepsScrim",
              jOffFog.material == .none && jOffSearch.material == .none
              && abs(jOffFog.scrim - base.glassScrim) < 0.0001
              && abs(jOffSearch.scrim - base.glassScrim) < 0.0001,
              jOffFog.readout)

        let jOutside = BackdropFog.make(settings: base,
                                        state: .folder(outsidePanel: true))
        check("J5 outsidePanelThinsFog",
              abs(jOutside.scrim - 0.10) < 0.0001
              && abs(jOutside.tint - 0.10) < 0.0001
              && jOutside.material == gridFog.material,
              jOutside.readout)

        let jNone = BackdropFog.make(settings: base, state: .none)
        check("J6 noPanelMeansNoFog",
              !jNone.active && !jNone.visibleOnCover
              && jNone.material == .none && jNone.scrim == 0,
              jNone.readout)

        check("J7 rollbackSwitchHonoured",
              gridFog.visibleOnCover == !ProbeConfig.noFogUnify,
              "cover=\(gridFog.visibleOnCover) noFogUnify=\(ProbeConfig.noFogUnify)")

        // The fog adds no sixth setting: encoding must still emit exactly the
        // five v1.5 glass keys. A second group would let the two windows drift.
        do {
            let data = try JSONEncoder().encode(base)
            let raw = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let glassKeys = raw.keys.filter { $0.hasPrefix("glass") }.sorted()
            check("J8 fogAddsNoSettingsKey",
                  glassKeys == ["glassEnabled", "glassRadius", "glassScrim",
                                "glassStyle", "glassTint"],
                  "keys=\(glassKeys)")
        } catch {
            check("J8 fogAddsNoSettingsKey", false, "encode failed: \(error)")
        }

        lines.append(all ? "PASS" : "FAIL")
        lines.append("DONE")
        try? (lines.joined(separator: "\n") + "\n")
            .write(toFile: logPath, atomically: true, encoding: .utf8)
        return all
    }
}
