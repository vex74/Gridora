import AppKit
import SwiftUI

/// Single source of truth for the visual language. The launcher stays near-black
/// cold with one sharp signal orange (~10% weight); the settings panel is a
/// deliberate light exception with the system blue as its control colour
/// (see .impeccable.md and .cursorrules). Components must read these constants
/// instead of spelling out a second copy of a colour, radius or type size.
enum DesignTokens {
    // MARK: Main launcher

    static let canvas = Color(red: 0.045, green: 0.05, blue: 0.065)
    static let panelSurface = Color(red: 0.07, green: 0.075, blue: 0.095)
    /// The only saturated accent in the launcher. Used for the focused search
    /// field, the section marker and the single warm aurora glow.
    static let signal = Color(red: 1.0, green: 0.36, blue: 0.21)

    // MARK: Ambient backdrop (low chroma, no violet / magenta / neon)

    static let auroraCoolA = Color(red: 0.10, green: 0.13, blue: 0.17)
    static let auroraCoolB = Color(red: 0.09, green: 0.11, blue: 0.15)
    static let auroraCoolC = Color(red: 0.12, green: 0.14, blue: 0.18)
    static let auroraSteel = Color(red: 0.06, green: 0.075, blue: 0.10)
    static let auroraDeep = Color(red: 0.03, green: 0.035, blue: 0.05)
    static let auroraWarm = Color(red: 0.62, green: 0.28, blue: 0.14)
    /// The warm accent is allowed to be more saturated, but its alpha keeps it
    /// well under the 10% visual budget.
    static let auroraWarmWeight: Double = 0.16

    // MARK: Settings panel (light)

    static let settingsAccent = Color(red: 0.03, green: 0.44, blue: 1.0)
    static let settingsCard = Color(red: 0.955, green: 0.955, blue: 0.965)
    static let settingsDanger = Color(red: 0.85, green: 0.22, blue: 0.2)
    static let settingsWarning = Color(red: 0.72, green: 0.33, blue: 0.12)
    static let settingsText = Color.black.opacity(0.85)
    static let settingsMuted = Color.black.opacity(0.40)
    static let settingsFaint = Color.black.opacity(0.35)
    static let settingsHairline = Color.black.opacity(0.08)

    // MARK: Geometry

    /// One radius for every large floating panel (folder / hidden / legacy
    /// PanelBackground). They used to be 24, 26 and 28 on three call sites.
    static let panelRadius: CGFloat = 24
    static let frameRadius: CGFloat = 12
    static let cardRadius: CGFloat = 10
    static let controlRadius: CGFloat = 6
    static let hairline: CGFloat = 0.7

    // MARK: Type

    static let rowTitle: CGFloat = 13
    static let caption: CGFloat = 11
    static let micro: CGFloat = 9.5

    // MARK: Interaction states

    static let focusRingWidth: CGFloat = 2
    /// Negative padding draws the ring 2pt outside the control's bounds.
    static let focusRingInset: CGFloat = -2
    static let hoverFill = Color.black.opacity(0.045)
    static let pressedFill = Color.black.opacity(0.09)

    /// Deterministic HSB-ish chroma used by --appearance-probe to keep the
    /// backdrop out of neon territory. No runtime colour guessing: a 0..1
    /// value derived only from the three RGB components.
    static func chroma(_ color: Color) -> Double {
        guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else { return 0 }
        let r = rgb.redComponent, g = rgb.greenComponent, b = rgb.blueComponent
        let high = max(r, g, b), low = min(r, g, b)
        return high > 0 ? (high - low) / high : 0
    }
}
