import Foundation

/// One set of paging rules for the whole app.
///
/// The main grid pages through `ScrollEngine` (display-linked spring) and the
/// open folder panel slides its 3 × 3 pages in SwiftUI. Those are two very
/// different renderers, but they must not *feel* different: same speed slider,
/// same "one physical flick = one page" rule, same threshold for a deliberate
/// short swipe. Every number that decides a page turn lives here so the two
/// paths cannot drift apart again.
///
/// Pure functions only — no state, no AppKit — so `--folder-interaction-probe`
/// and `--wheel-probe` can assert them directly.
enum PagingRules {

    /// `Settings.scrollSpeed` is a 0.4…2.0 multiplier. It scales the time axis
    /// of the settle spring, never its stiffness, so the damping ratio (and
    /// therefore the no-overshoot behaviour) is identical at every speed.
    static func pace(_ speed: Double) -> CGFloat {
        CGFloat(min(max(speed, 0.4), 2.0))
    }

    /// Discrete wheel notches closer together than this are one physical
    /// flick, not two. Derived from `systemUptime`, never `event.timestamp`
    /// (synthetic events carry a constant timestamp of 0).
    static func burstWindow(pace: CGFloat) -> TimeInterval {
        TimeInterval(min(max(0.09 / pace, 0.05), 0.14))
    }

    /// How far a gesture must travel before it wins a page even though it
    /// never crossed the halfway point: min(10% of a page, 90 pt), divided by
    /// pace so lowering the speed slider also raises the bar for a short flick
    /// instead of only shrinking the on-screen drag.
    static func flickThreshold(extent: CGFloat, pace: CGFloat) -> CGFloat {
        guard extent > 1 else { return 0 }
        return min(extent * 0.10, 90) / pace
    }

    /// One gesture, one page. A fast swipe can project a page past the nearest
    /// boundary; the short-flick bonus then used to add a second one, which is
    /// how a single flick jumped two pages. Clamp to where the gesture began,
    /// plus or minus one.
    static func limit(_ page: CGFloat, toGestureStartingAt startPage: CGFloat) -> CGFloat {
        min(max(page, startPage - 1), startPage + 1)
    }

    /// Boundary index a given page count allows.
    static func clampPage(_ page: Double, count: Int) -> Int {
        min(max(Int(page.rounded()), 0), max(0, count - 1))
    }
}
