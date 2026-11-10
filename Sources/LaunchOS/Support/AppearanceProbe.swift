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
        a.searchGlassEnabled = true
        a.searchGlassStyle = .regular
        a.searchGlassTint = 0.32
        a.searchGlassRadius = 14
        a.searchScrim = 0.26
        let s1 = GlassPreviewSnapshot(settings: a)
        var b = a
        b.searchGlassEnabled = false
        b.searchGlassStyle = .clear
        b.searchGlassTint = 0.60
        b.searchGlassRadius = 24
        b.searchScrim = 0.48
        let s2 = GlassPreviewSnapshot(settings: b)
        let tracks = s1 != s2 && !s2.enabled && s2.style == .clear
            && s2.tintPercent == 60 && s2.radius == 24 && s2.scrimPercent == 48
            && s2.readout.contains("通透") && s2.readout.contains("24pt")
        check("A preview", tracks, "s1=\(s1.readout) s2=\(s2.readout)")
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
        let rangesOK = Settings.searchGlassTintRange == 0...0.75
            && Settings.searchGlassRadiusRange == 6...28
            && Settings.searchScrimRange == 0...0.60
            && Settings.iconScaleRange == 0.78...1.4
        check("C ranges", rangesOK,
              "tint=0...0.75 radius=6...28 scrim=0...0.60 iconScale=0.78...1.4")

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

        // G. Folder glass must be independently adjustable. These are pure
        // Settings -> snapshot checks plus a real JSON round-trip, not a
        // look-alike that re-implements the decoding rules.
        var base = Settings()
        base.folderGlassEnabled = true
        base.folderGlassStyle = .regular
        base.folderGlassTint = Settings.defaultFolderGlassTint
        base.folderGlassRadius = Settings.defaultFolderGlassRadius
        base.folderGlassScrim = Settings.defaultFolderGlassScrim
        let f1 = FolderGlassSnapshot(settings: base)
        var g = base
        g.folderGlassEnabled = false
        g.folderGlassStyle = .clear
        g.folderGlassTint = 0.62
        g.folderGlassRadius = 32
        g.folderGlassScrim = 0.50
        let f2 = FolderGlassSnapshot(settings: g)
        check("G1 tracksAllFive", f1 != f2 && !f2.enabled && f2.style == .clear
              && f2.tintPercent == 62 && f2.radius == 32 && f2.scrimPercent == 50
              && f2.modeText == "近黑实底" && f2.readout.contains("32pt"),
              "f1=\(f1.readout) f2=\(f2.readout)")
        check("G2 stable", FolderGlassSnapshot(settings: base) == f1,
              "same Settings -> same snapshot=\(FolderGlassSnapshot(settings: base) == f1)")

        var h = base
        h.searchGlassEnabled = false
        h.searchGlassStyle = .clear
        h.searchGlassTint = 0.70
        h.searchGlassRadius = 8
        h.searchScrim = 0.60
        check("G3 searchCannotMoveFolder",
              FolderGlassSnapshot(settings: h) == f1
              && GlassPreviewSnapshot(settings: h) != GlassPreviewSnapshot(settings: base),
              "folderUnchanged=\(FolderGlassSnapshot(settings: h) == f1) "
              + "searchChanged=\(GlassPreviewSnapshot(settings: h) != GlassPreviewSnapshot(settings: base))")
        var i2 = base
        i2.folderGlassTint = 0.60
        i2.folderGlassRadius = 30
        check("G4 folderCannotMoveSearch",
              GlassPreviewSnapshot(settings: i2) == GlassPreviewSnapshot(settings: base),
              "searchUnchanged=\(GlassPreviewSnapshot(settings: i2) == GlassPreviewSnapshot(settings: base))")

        check("G5 defaultsAndRanges",
              Settings.defaultFolderGlassRadius == Double(DesignTokens.panelRadius)
              && Settings.defaultFolderGlassTint == 0.38
              && Settings.defaultFolderGlassScrim == 0.28
              && Settings.folderGlassTintRange == 0...0.75
              && Settings.folderGlassRadiusRange == 8...36
              && Settings.folderGlassScrimRange == 0...0.60,
              "radius=\(Int(Settings.defaultFolderGlassRadius)) "
              + "tint=\(f(Settings.defaultFolderGlassTint)) scrim=\(f(Settings.defaultFolderGlassScrim))")

        do {
            let encoded = try JSONEncoder().encode(g)
            let decoded = try JSONDecoder().decode(Settings.self, from: encoded)
            check("G6 stateRoundTrip",
                  !decoded.folderGlassEnabled && decoded.folderGlassStyle == .clear
                  && decoded.folderGlassTint == 0.62 && decoded.folderGlassRadius == 32
                  && decoded.folderGlassScrim == 0.50,
                  "enabled=\(decoded.folderGlassEnabled) style=\(decoded.folderGlassStyle.rawValue) "
                  + "tint=\(f(decoded.folderGlassTint)) radius=\(Int(decoded.folderGlassRadius)) "
                  + "scrim=\(f(decoded.folderGlassScrim))")

            var raw = (try JSONSerialization.jsonObject(with: encoded)) as? [String: Any] ?? [:]
            raw["folderGlassStyle"] = "bogus"
            raw["folderGlassTint"] = 9.0
            raw["folderGlassRadius"] = -4
            raw["folderGlassScrim"] = 1.4
            let bad = try JSONDecoder().decode(
                Settings.self,
                from: try JSONSerialization.data(withJSONObject: raw))
            check("G7 corruptClamped",
                  bad.folderGlassStyle == .regular && bad.folderGlassTint == 0.75
                  && bad.folderGlassRadius == 8 && bad.folderGlassScrim == 0.60,
                  "style=\(bad.folderGlassStyle.rawValue) tint=\(f(bad.folderGlassTint)) "
                  + "radius=\(Int(bad.folderGlassRadius)) scrim=\(f(bad.folderGlassScrim))")

            for key in ["folderGlassEnabled", "folderGlassStyle", "folderGlassTint",
                        "folderGlassRadius", "folderGlassScrim"] {
                raw.removeValue(forKey: key)
            }
            let legacy = try JSONDecoder().decode(
                Settings.self,
                from: try JSONSerialization.data(withJSONObject: raw))
            check("G8 legacyUpgrade",
                  legacy.folderGlassEnabled
                  && legacy.folderGlassStyle == .regular
                  && legacy.folderGlassTint == Settings.defaultFolderGlassTint
                  && legacy.folderGlassRadius == Settings.defaultFolderGlassRadius
                  && legacy.folderGlassScrim == Settings.defaultFolderGlassScrim,
                  "enabled=\(legacy.folderGlassEnabled) tint=\(f(legacy.folderGlassTint)) "
                  + "radius=\(Int(legacy.folderGlassRadius)) scrim=\(f(legacy.folderGlassScrim))")
        } catch {
            check("G6 stateRoundTrip", false, "JSON error=\(error)")
        }

        // H. The collapsed folder tile must be driven by the SAME five keys as
        // the open panel. Separate formulas here would be the exact bug that
        // let the small icon stay a black square after the panel was glassed.
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

        var j = base
        j.folderGlassEnabled = false
        j.folderGlassStyle = .clear
        j.folderGlassTint = 0.61
        j.folderGlassRadius = 34
        j.folderGlassScrim = 0.52
        let icon1 = FolderIconGlass(settings: j, size: iconSize)
        check("H3 tracksAllFive",
              !icon1.enabled && icon1.style == .clear && icon1.tintPercent == 61
              && icon1.radius == 34 && icon1.scrimPercent == 52
              && icon1.modeText == "原材质"
              && abs(icon1.innerDim - 0.26) < 0.001
              && icon1 != icon0,
              "icon1=\(icon1.readout) dim=\(f(icon1.innerDim))")

        var k = base
        k.folderGlassRadius = 8
        let tight = FolderIconGlass(settings: k, size: iconSize)
        k.folderGlassRadius = 36
        let round = FolderIconGlass(settings: k, size: iconSize)
        check("H4 radiusClampedAndMonotonic",
              tight.cornerRadius >= iconSize * 0.10
              && round.cornerRadius <= iconSize * 0.42
              && tight.cornerRadius < icon0.cornerRadius
              && icon0.cornerRadius < round.cornerRadius,
              "8pt=\(f(tight.cornerRadius)) 24pt=\(f(icon0.cornerRadius)) "
              + "36pt=\(f(round.cornerRadius))")

        var l = base
        l.searchGlassEnabled = false
        l.searchGlassStyle = .clear
        l.searchGlassTint = 0.70
        l.searchGlassRadius = 8
        l.searchScrim = 0.60
        check("H5 searchCannotMoveEitherFolderSurface",
              FolderIconGlass(settings: l, size: iconSize) == icon0
              && FolderGlassSnapshot(settings: l) == panel0
              && GlassPreviewSnapshot(settings: l) != GlassPreviewSnapshot(settings: base),
              "iconUnchanged=\(FolderIconGlass(settings: l, size: iconSize) == icon0) "
              + "panelUnchanged=\(FolderGlassSnapshot(settings: l) == panel0)")

        let small = FolderIconGlass(settings: base, size: 46)
        check("H6 sizeOnlyChangesGeometry",
              small.enabled == icon0.enabled && small.style == icon0.style
              && small.tintPercent == icon0.tintPercent
              && small.radius == icon0.radius
              && small.scrimPercent == icon0.scrimPercent
              && small.cornerRadius < icon0.cornerRadius,
              "46pt=\(f(small.cornerRadius)) 80pt=\(f(icon0.cornerRadius))")

        let expectedEnabled = !ProbeConfig.folderIconNoGlass
            && (ProbeConfig.folderIconPlate || ProbeConfig.noRaster)
        check("H7 rollbackSwitchHonoured",
              icon0.enabled == expectedEnabled,
              "iconEnabled=\(icon0.enabled) expected=\(expectedEnabled) "
              + "noGlass=\(ProbeConfig.folderIconNoGlass) "
              + "plate=\(ProbeConfig.folderIconPlate) noRaster=\(ProbeConfig.noRaster)")

        lines.append(all ? "PASS" : "FAIL")
        lines.append("DONE")
        try? (lines.joined(separator: "\n") + "\n")
            .write(toFile: logPath, atomically: true, encoding: .utf8)
        return all
    }
}
