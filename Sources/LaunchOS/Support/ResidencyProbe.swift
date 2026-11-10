import AppKit
import Foundation
import QuartzCore

/// Assertions for `Gridora --residency-probe`.
///
/// The bug being guarded: `quitOnHide = true` used to terminate the process on
/// every hide, and a Carbon `EventHotKey` dies with its process — so a recorded
/// F3 stopped working the moment the launcher closed. A boolean-only test
/// cannot prove this; the live stages below really hide the window, keep the
/// process running, invoke the *actual* hotkey handler, and assert the window
/// comes back. Reaching stage 2 is itself the proof that nothing terminated.
///
/// Also covers the macOS 15 reveal: `fadeShow` must leave the content layer at
/// identity with no transform animation, while `show` (the old centre-out A/B
/// control) must still be detectable by the very same check.
@MainActor
enum ResidencyProbe {
    static let logPath = "/tmp/launchos-residency.log"

    private static var lines: [String] = []
    private static var all = true

    static func startIfNeeded(delegate: AppDelegate, model: LauncherModel) {
        guard ProcessInfo.processInfo.arguments.contains("--residency-probe") else { return }
        try? FileManager.default.removeItem(atPath: logPath)
        lines = ["RESIDENCY PROBE"]
        all = true
        // Let the initial show / Carbon registration settle first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            stage1(delegate: delegate, model: model)
        }
    }

    private static func check(_ tag: String, _ ok: Bool, _ detail: String) {
        lines.append("\(tag) \(ok ? "PASS" : "FAIL") \(detail)")
        if !ok { all = false }
    }

    private static func info(_ text: String) { lines.append("INFO \(text)") }

    private static func finish() {
        lines.append(all ? "PASS" : "FAIL")
        lines.append("DONE")
        try? (lines.joined(separator: "\n") + "\n")
            .write(toFile: logPath, atomically: true, encoding: .utf8)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
    }

    private static func decode(_ settingsJSON: String) -> Settings? {
        let json = "{\"pages\":[],\"hidden\":[],\"settings\":\(settingsJSON),"
            + "\"usage\":{},\"manualHidden\":[],\"pinned\":[]}"
        return (try? JSONDecoder().decode(PersistedState.self,
                                          from: Data(json.utf8)))?.settings
    }

    // MARK: A/B/D — pure decisions, real state decoding, real layer animation

    private static func stage1(delegate: AppDelegate, model: LauncherModel) {
        let defaults = Settings()
        check("A factory default is resident",
              !defaults.quitOnHide && defaults.residencyChoiceVersion == 1,
              "quitOnHide=\(defaults.quitOnHide) version=\(defaults.residencyChoiceVersion)")

        let legacy = decode("{\"quitOnHide\":true}")
        check("A old state (no version) upgraded",
              legacy?.quitOnHide == false && legacy?.residencyChoiceVersion == 1,
              "quitOnHide=\(legacy?.quitOnHide.description ?? "nil") "
              + "version=\(legacy?.residencyChoiceVersion.description ?? "nil")")
        let explicit = decode("{\"quitOnHide\":true,\"residencyChoiceVersion\":1}")
        check("A explicit exit respected", explicit?.quitOnHide == true,
              "quitOnHide=\(explicit?.quitOnHide.description ?? "nil")")
        let explicitOff = decode("{\"quitOnHide\":false,\"residencyChoiceVersion\":1}")
        check("A explicit resident respected", explicitOff?.quitOnHide == false,
              "quitOnHide=\(explicitOff?.quitOnHide.description ?? "nil")")
        let empty = decode("{}")
        check("A missing keys are resident", empty?.quitOnHide == false,
              "quitOnHide=\(empty?.quitOnHide.description ?? "nil")")

        var written = Settings()
        written.quitOnHide = true
        let roundtrip = (try? JSONEncoder().encode(written))
            .flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
        check("A encode/decode roundtrip",
              roundtrip?.quitOnHide == true && roundtrip?.residencyChoiceVersion == 1,
              "quitOnHide=\(roundtrip?.quitOnHide.description ?? "nil") "
              + "version=\(roundtrip?.residencyChoiceVersion.description ?? "nil")")

        var exiting = Settings()
        exiting.quitOnHide = true
        check("B policy resident (product path)",
              !ResidencyPolicy.shouldExitOnHide(settings: defaults, diagnosticMode: false, quitProbe: false),
              "decision=\(ResidencyPolicy.shouldExitOnHide(settings: defaults, diagnosticMode: false, quitProbe: false))")
        check("B policy explicit exit (product path)",
              ResidencyPolicy.shouldExitOnHide(settings: exiting, diagnosticMode: false, quitProbe: false),
              "decision=\(ResidencyPolicy.shouldExitOnHide(settings: exiting, diagnosticMode: false, quitProbe: false))")
        check("B diagnostics stay alive",
              !ResidencyPolicy.shouldExitOnHide(settings: exiting, diagnosticMode: true, quitProbe: false),
              "decision=\(ResidencyPolicy.shouldExitOnHide(settings: exiting, diagnosticMode: true, quitProbe: false))")
        check("B quit-probe forces terminate path",
              ResidencyPolicy.shouldExitOnHide(settings: defaults, diagnosticMode: true, quitProbe: true),
              "decision=\(ResidencyPolicy.shouldExitOnHide(settings: defaults, diagnosticMode: true, quitProbe: true))")

        check("C Carbon hotkey registered at launch",
              GlobalHotKey.shared.hasAnyHotKey
              && GlobalHotKey.shared.activeRegistrationCount > 0,
              "combos=\(GlobalHotKey.shared.registeredCombos.map(\.label)) "
              + "active=\(GlobalHotKey.shared.activeRegistrationCount) "
              + "status=\(GlobalHotKey.shared.lastStatus)")

        let envMode = ProcessInfo.processInfo.environment["LAUNCHOS_OPEN_ANIM"]
        check("D macOS 15 fade is default",
              envMode == nil ? OpenAnimationConfig.mode == .fade : true,
              "mode=\(OpenAnimationConfig.mode.rawValue) env=\(envMode ?? "nil")")
        let savedReduce = Motion.reduceMotion
        Motion.reduceMotion = true
        let reducedIn = Motion.fadeInDuration
        let reducedOut = Motion.fadeOutDuration
        Motion.reduceMotion = false
        let normalIn = Motion.fadeInDuration
        let normalOut = Motion.fadeOutDuration
        Motion.reduceMotion = savedReduce
        check("D fade durations + Reduce Motion",
              reducedIn < 0.01 && reducedOut < 0.01
              && normalIn > 0.2 && normalIn < 0.4
              && normalOut > 0.15 && normalOut <= normalIn,
              "in=\(normalIn) out=\(normalOut) reducedIn=\(reducedIn) reducedOut=\(reducedOut)")

        if let window = delegate.probeWindow, let layer = window.contentView?.layer {
            WindowReveal.fadeShow(window: window, cover: nil, duration: 0.30)
            let t = layer.transform
            let identity = abs(t.m11 - 1) < 0.0001 && abs(t.m22 - 1) < 0.0001
                && abs(t.m41) < 0.01 && abs(t.m42) < 0.01
            let fadeKeys = layer.animationKeys() ?? []
            check("D fade keeps grid at identity",
                  identity && !fadeKeys.contains("launchos.windowReveal"),
                  "m11=\(t.m11) tx=\(t.m41) ty=\(t.m42) keys=\(fadeKeys)")
            WindowReveal.show(window: window, cover: nil, duration: 0.30,
                              startScale: Motion.openStartScale)
            let scaleKeys = layer.animationKeys() ?? []
            check("D scale control still detectable",
                  scaleKeys.contains("launchos.windowReveal"),
                  "keys=\(scaleKeys)")
            WindowReveal.reset(window)
        } else {
            check("D fade keeps grid at identity", false, "no content layer")
            check("D scale control still detectable", false, "no content layer")
        }

        info("stage2: hideLauncher (process must survive)")
        delegate.hideLauncher()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            stage2(delegate: delegate, model: model)
        }
    }

    // MARK: E — the process is still running after a real hide

    private static func stage2(delegate: AppDelegate, model: LauncherModel) {
        let visible = delegate.probeWindow?.isVisible ?? true
        check("E process survived hide", true, "reached stage2 (no terminate fired)")
        check("E window hidden", !visible && !model.isShown,
              "visible=\(visible) isShown=\(model.isShown)")
        check("E Carbon hotkey still registered",
              GlobalHotKey.shared.hasAnyHotKey
              && GlobalHotKey.shared.activeRegistrationCount > 0,
              "active=\(GlobalHotKey.shared.activeRegistrationCount) "
              + "combos=\(GlobalHotKey.shared.registeredCombos.map(\.label))")

        info("stage3: invoke the REAL global hotkey handler (as if F3 were pressed)")
        GlobalHotKey.shared.handler?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            stage3(delegate: delegate, model: model)
        }
    }

    // MARK: F — hidden launcher really comes back, then Dock reopen works

    private static func stage3(delegate: AppDelegate, model: LauncherModel) {
        let visible = delegate.probeWindow?.isVisible ?? false
        let alpha = delegate.probeWindow?.alphaValue ?? 0
        check("F hotkey reopened hidden launcher", visible && model.isShown,
              "visible=\(visible) isShown=\(model.isShown)")
        check("F window faded back in", alpha > 0.9, "alpha=\(alpha)")

        if let layer = delegate.probeWindow?.contentView?.layer {
            let t = layer.transform
            let identity = abs(t.m11 - 1) < 0.0001 && abs(t.m22 - 1) < 0.0001
                && abs(t.m41) < 0.01 && abs(t.m42) < 0.01
            let keys = layer.animationKeys() ?? []
            check("F real show used pure fade", identity && !keys.contains("launchos.windowReveal"),
                  "m11=\(t.m11) tx=\(t.m41) keys=\(keys)")
        } else {
            check("F real show used pure fade", false, "no content layer")
        }

        info("stage4: hide again, then simulate a Dock click")
        delegate.hideLauncher()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            stage4(delegate: delegate, model: model)
        }
    }

    private static func stage4(delegate: AppDelegate, model: LauncherModel) {
        let visible = delegate.probeWindow?.isVisible ?? true
        check("G window hidden again", !visible, "visible=\(visible)")
        check("G hotkey still alive after 2nd hide",
              GlobalHotKey.shared.hasAnyHotKey,
              "active=\(GlobalHotKey.shared.activeRegistrationCount)")
        // The existing delegate returns true (AppKit's normal "handled") and
        // routes visible→hide / hidden→show itself. Only the resulting window
        // state is a meaningful assertion here.
        let handled = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        check("G Dock reopen delegated", handled, "returned=\(handled)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            stage5(delegate: delegate, model: model)
        }
    }

    private static func stage5(delegate: AppDelegate, model: LauncherModel) {
        check("H Dock reopen shows launcher",
              (delegate.probeWindow?.isVisible ?? false) && model.isShown,
              "visible=\(delegate.probeWindow?.isVisible ?? false) isShown=\(model.isShown)")
        info("settings at runtime: quitOnHide=\(model.settings.quitOnHide) "
             + "version=\(model.settings.residencyChoiceVersion)")
        finish()
    }
}
