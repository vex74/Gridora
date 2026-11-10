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

        lines.append(all ? "PASS" : "FAIL")
        lines.append("DONE")
        try? (lines.joined(separator: "\n") + "\n")
            .write(toFile: logPath, atomically: true, encoding: .utf8)
        return all
    }
}
