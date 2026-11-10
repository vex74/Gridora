import AppKit
import QuartzCore

/// Receives raw scroll-wheel deltas and commits them exactly once per display
/// frame. On a ProMotion display the link fires at up to 120 Hz; on a 60 Hz
/// display it follows 60 Hz. Delivering deltas per NSEvent instead meant two
/// or three redundant body invalidations between frames and a visible stutter.
///
/// The same link owns the settle animation. SwiftUI's `withAnimation` was not
/// usable here: it writes the *final* value into the model immediately and
/// interpolates only in the view, so a wheel event arriving mid-spring used to
/// read the destination instead of the current on-screen position and jump.
@MainActor
final class ScrollEngine: NSObject {

    private enum Mode {
        case idle
        case tracking      // wheel / trackpad events are arriving
        case settling      // spring toward a page boundary
        case jumping       // duration-based tween for a multi-page jump
    }

    private weak var owner: LauncherModel?
    private let proxy = DisplayLinkProxy()
    private var link: CADisplayLink?
    private var idleWork: DispatchWorkItem?

    private var mode: Mode = .idle
    private var pendingDelta: CGFloat = 0
    /// Momentum-ended events still carry a final delta. Applying it inside the
    /// event callback would invalidate a view outside vsync; the frame loop
    /// picks it up first and settles on that same frame.
    private var pendingSettle = false
    private var velocity: CGFloat = 0            // points / second, scrollPos units
    private var settleVelocity: CGFloat = 0
    private var target: CGFloat = 0
    private var stiffness = Motion.pageStiffness
    private var damping = Motion.pageDamping
    private var lastTimestamp: CFTimeInterval = 0
    private var lastDeltaTimestamp: CFTimeInterval = 0
    private var momentumActive = false
    private var jumpStart: CGFloat = 0
    private var jumpElapsed: TimeInterval = 0
    private var jumpDuration: TimeInterval = 0
    /// On-screen position at the start of the current wheel / trackpad
    /// gesture. A short but deliberate flick used to be snapped back to its
    /// own starting page, so the user had to flick a second time.
    private var gestureStart: CGFloat?

    init(owner: LauncherModel) {
        self.owner = owner
        super.init()
    }

    /// The display link must be created from a view (or screen) so AppKit can
    /// bind it to the right display. `NSView.displayLink` is macOS 14+.
    func attach(to view: NSView) {
        guard link == nil else { return }
        let displayLink = view.displayLink(target: proxy,
                                           selector: #selector(DisplayLinkProxy.tick(_:)))
        // Ask for the full native range. Without this, macOS may keep the
        // link at 60 Hz even on a 120 Hz ProMotion panel.
        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 60,
                                                               maximum: 120,
                                                               preferred: 120)
        displayLink.isPaused = true
        displayLink.add(to: .main, forMode: .common)
        proxy.onFrame = { [weak self] timestamp in
            // The link is registered on the main run loop, so this callback is
            // already on the main thread — hop into the actor without a queue
            // dispatch (which would add a frame of latency).
            MainActor.assumeIsolated { self?.frame(timestamp: timestamp) }
        }
        link = displayLink
    }

    // MARK: - Pacing

    /// `scrollSpeed` already scales raw trackpad deltas in LauncherModel.
    /// Without this, it had no effect at all on mouse-wheel paging (a fixed
    /// duration spring) or on the short-flick threshold, so turning the
    /// "scrolling speed" slider down did not actually make paging feel slower.
    /// The spring's coefficients stay exactly at the measured 360/38. Pacing
    /// scales only its integration step (dt * pace), i.e. the time axis, so
    /// the damping ratio never changes. Scaling stiffness by pace² instead was
    /// tried and rejected: at pace = 2 the explicit Euler step overshot a
    /// whole page on a single flick.
    private var pace: CGFloat {
        PagingRules.pace(owner?.settings.scrollSpeed ?? 1.0)
    }

    /// Cached at the start of a settle so the frame loop does not read
    /// settings on every vsync.
    private var settlePace: CGFloat = 1

    // MARK: - Input

    /// Page boundary an in-flight flip is heading for. Wheel notches arriving
    /// during that flip must be counted from this destination, not from the
    /// rounded on-screen position: the latter re-targets the page the first
    /// notch already requested and makes the second notch look like a no-op.
    var destination: CGFloat? {
        switch mode {
        case .settling, .jumping: return target
        case .idle, .tracking: return nil
        }
    }

    /// `delta` is already the signed change to apply to `scrollPos`.
    func enqueue(_ delta: CGFloat, phase: NSEvent.Phase, momentumPhase: NSEvent.Phase) {
        guard let owner else { return }

        // A gesture starts at the position actually on screen. Momentum tails
        // belong to the same gesture, so only a new gesture (or interrupting
        // an in-flight flip) resets the origin.
        if mode == .idle || mode == .settling || mode == .jumping || phase == .began {
            gestureStart = owner.scrollPos
        }

        // Fresh finger input wins over an in-flight spring or jump; keep the
        // current position, drop the old velocity so there is no visible snap.
        if mode == .settling || mode == .jumping {
            settleVelocity = 0
            velocity = 0
        }

        pendingDelta += delta
        pendingSettle = false
        if phase == .began { momentumActive = false }
        if momentumPhase == .began || momentumPhase == .changed { momentumActive = true }

        // `phase == .ended` (fingers lifted) must NOT settle: trackpad momentum
        // events arrive right after it. Snapping there used to cut the fling
        // short and made scrolling feel like it hit a wall.
        let finished = momentumPhase == .ended
            || momentumPhase == .cancelled
            || phase == .cancelled
        if finished { momentumActive = false }

        mode = .tracking
        resumeLink()
        cancelIdle()

        if finished {
            // Resolve on the next vsync: that frame applies the last delta,
            // measures its velocity, and starts the spring with the correct
            // carry-over — all inside a single display-synced update.
            pendingSettle = true
        } else {
            // Momentum tails can have gaps, so give them a longer leash.
            scheduleIdle(delay: momentumActive ? 0.22 : 0.12)
        }
    }

    /// Programmatic page change (page dots, keyboard, edge flip, drop snap).
    /// Short hops use the spring so a fling blends naturally into the snap;
    /// multi-page jumps use a fixed-duration ease, since a spring with a
    /// 10 000-point displacement would reach absurd speed and overshoot.
    func animate(to destination: CGFloat) {
        guard let owner else { return }
        cancelIdle()
        target = destination
        pendingDelta = 0
        pendingSettle = false
        settleVelocity = 0
        velocity = 0
        gestureStart = nil
        let distance = abs(destination - owner.scrollPos)
        let pace = self.pace
        settlePace = pace

        if distance > owner.pageExtent * 1.6 {
            jumpStart = owner.scrollPos
            jumpElapsed = 0
            jumpDuration = min(0.62, 0.30 + 0.035 * Double(distance / max(owner.pageExtent, 1)))
                / Double(pace)
            mode = .jumping
        } else {
            stiffness = Motion.pageStiffness
            damping = Motion.pageDamping
            mode = .settling
        }
        resumeLink()
    }

    /// Hard stop: used when a panel opens, the window hides, or the user grabs
    /// an icon. Leaves the pager exactly where it is on screen.
    func cancel() {
        cancelIdle()
        mode = .idle
        pendingDelta = 0
        pendingSettle = false
        velocity = 0
        settleVelocity = 0
        momentumActive = false
        jumpElapsed = 0
        lastTimestamp = 0
        lastDeltaTimestamp = 0
        gestureStart = nil
        pauseLink()
    }

    // MARK: - Settling

    /// Only marks the intent. The actual switch happens on the next vsync,
    /// after that frame has applied its accumulated delta, so no model write
    /// ever escapes the display loop.
    private func settle() {
        guard owner != nil else { return }
        cancelIdle()
        pendingSettle = true
        resumeLink()
    }

    private func beginSettle(timestamp: CFTimeInterval) {
        guard let owner, owner.pageExtent > 1 else {
            mode = .idle
            pauseLink()
            return
        }
        pendingSettle = false

        let extent = owner.pageExtent
        let current = owner.scrollPos

        // A fling carries its speed into the spring. Decay it by the time
        // since the last real delta (idle frames don't erase velocity, but a
        // long pause should), and never jump more than one page past the
        // nearest boundary.
        let idle = max(0, timestamp - lastDeltaTimestamp)
        let decay = CGFloat(exp(-4.0 * idle))
        let residual = max(-Motion.maxSettleVelocity,
                           min(Motion.maxSettleVelocity, velocity * decay))
        settleVelocity = residual

        let nearest = (current / extent).rounded()
        let projected = ((current + residual * 0.14) / extent).rounded()
        var page = min(max(projected, nearest - 1), nearest + 1)
        let pace = self.pace
        // Lower "scrolling speed" also raises the bar for a short flick to win
        // a page, so the slider dampens one-flick paging instead of only
        // shrinking the on-screen drag. At the 1.0 default this is the
        // original, probe-verified min(10% of a page, 90pt). The folder panel
        // uses the very same rule through `PagingRules`.
        let flickThreshold = PagingRules.flickThreshold(extent: extent, pace: pace)

        // A gesture that moved a meaningful distance but never crossed half a
        // page used to snap back to where it started — the "it takes two
        // flicks to turn one page" report. Deliberate travel now wins one
        // page in the direction of the gesture. A tiny nudge (or a drag that
        // ended where it began) still settles on the nearest page.
        let startPos = gestureStart ?? current
        let startPage = (startPos / extent).rounded()
        let travel = current - startPos
        gestureStart = nil
        if projected == nearest, abs(travel) > flickThreshold {
            page = nearest + (travel > 0 ? 1 : -1)
        }
        // One gesture, one page. `projected` can already be a page past
        // `nearest` on a fast swipe, and the short-flick bonus used to add a
        // second one on top — a single flick then jumped from page 0 to 2.
        // Clamp to the page where the gesture began, plus or minus one.
        let limited = PagingRules.limit(page, toGestureStartingAt: startPage)
        let bounded = min(max(limited, 0), CGFloat(owner.pageCount - 1))
        target = bounded * extent
        WheelDiagnostics.log(String(format: "settle pos=%.1f start=%.0f travel=%.1f vel=%.0f nearest=%.0f projected=%.0f pace=%.2f flick=%.0f raw=%.0f -> page=%.0f",
                                    current, startPage, travel, residual, nearest,
                                    projected, pace, flickThreshold, page, bounded))

        settlePace = pace
        stiffness = Motion.pageStiffness
        damping = Motion.pageDamping
        mode = .settling
    }

    private func scheduleIdle(delay: TimeInterval) {
        cancelIdle()
        let work = DispatchWorkItem { [weak self] in
            self?.idleWork = nil
            self?.settle()
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelIdle() {
        idleWork?.cancel()
        idleWork = nil
    }

    // MARK: - Frame loop

    private func frame(timestamp: CFTimeInterval) {
        guard let owner, mode != .idle else {
            pauseLink()
            return
        }

        var dt = lastTimestamp > 0 ? timestamp - lastTimestamp : 1.0 / 120.0
        lastTimestamp = timestamp
        dt = min(max(dt, 1.0 / 240.0), 1.0 / 30.0)

        switch mode {
        case .tracking:
            if pendingDelta != 0 {
                let applied = pendingDelta
                pendingDelta = 0
                owner.scrollPos = owner.rubbered(owner.scrollPos + applied)
                let instant = applied / CGFloat(dt)
                velocity = velocity * 0.30 + instant * 0.70
                lastDeltaTimestamp = timestamp
            }
            // Velocity is decayed by elapsed time in `beginSettle` rather than
            // per idle frame, so a short pause in the event stream does not
            // erase the fling.
            if pendingSettle {
                beginSettle(timestamp: timestamp)
            }

        case .jumping:
            jumpElapsed += dt
            let t = min(1, jumpElapsed / max(jumpDuration, 0.01))
            // easeOutCubic: fast off the mark, gentle landing, no overshoot.
            let eased = 1 - pow(1 - t, 3)
            owner.scrollPos = jumpStart + (target - jumpStart) * eased
            if t >= 1 {
                owner.scrollPos = target
                mode = .idle
                pauseLink()
            }

        case .settling:
            // Two sub-steps keep the explicit Euler integration stable at
            // 60 Hz as well as 120 Hz. Integrate into a local and publish
            // exactly once per frame — two @Published writes per vsync used
            // to risk two separate view invalidations.
            // Only the time axis is scaled. Coefficients stay at 360/38, so
            // the damping ratio — and therefore the no-overshoot behaviour
            // verified at 60/120 Hz — is identical at every speed setting.
            let h = CGFloat(dt) * settlePace / 2
            let maxPos = CGFloat(owner.pageCount - 1) * owner.pageExtent
            var pos = owner.scrollPos
            for _ in 0..<2 {
                let displacement = pos - target
                let acceleration = -stiffness * displacement - damping * settleVelocity
                settleVelocity += acceleration * h
                pos = min(max(pos + settleVelocity * h, -48), maxPos + 48)
            }
            owner.scrollPos = pos

            if abs(pos - target) < 0.35 && abs(settleVelocity) < 12 {
                owner.scrollPos = target
                settleVelocity = 0
                velocity = 0
                mode = .idle
                lastTimestamp = 0
                pauseLink()
            }

        case .idle:
            pauseLink()
        }
    }

    private func resumeLink() {
        guard let link else { return }
        if link.isPaused {
            // Re-declare the range on every wake-up. Moving the window to a
            // different screen (or the system renegotiating ProMotion after a
            // pause) can otherwise silently drop the link back to 60 Hz.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60,
                                                             maximum: 120,
                                                             preferred: 120)
            lastTimestamp = 0
            link.isPaused = false
        }
    }

    private func pauseLink() {
        link?.isPaused = true
        lastTimestamp = 0
    }
}

/// Plain NSObject target: CADisplayLink retains its target, and an @objc
/// selector cannot be main-actor isolated. The closure runs on the main run
/// loop and re-enters the actor with `assumeIsolated`.
private final class DisplayLinkProxy: NSObject {
    var onFrame: ((CFTimeInterval) -> Void)?

    @objc func tick(_ link: CADisplayLink) {
        onFrame?(link.timestamp)
    }
}
