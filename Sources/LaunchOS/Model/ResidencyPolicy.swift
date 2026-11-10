import Foundation

/// Single source of truth for "does hiding the launcher kill the process?".
///
/// A Carbon `EventHotKey` is owned by the process that registered it. The old
/// factory behaviour (`quitOnHide = true`) tore the process down on every
/// hide, so a recorded start key such as F3 became dead until the user
/// clicked the pinned Dock icon — exactly the "快捷键关闭了就无法打开" bug.
///
/// Keeping the process alive as `LSUIElement` / `.accessory` has no visible
/// cost: no Dock tile, no running indicator, no menu-bar takeover. Diagnostics
/// are the one exception in the other direction: a `--*-probe` run must stay
/// alive until its own harness finishes, except `--quit-probe`, whose whole
/// purpose is to drive the real terminate path.
enum ResidencyPolicy {
    static func shouldExitOnHide(settings: Settings,
                                 diagnosticMode: Bool,
                                 quitProbe: Bool) -> Bool {
        if quitProbe { return true }
        guard settings.quitOnHide else { return false }
        return !diagnosticMode
    }
}
