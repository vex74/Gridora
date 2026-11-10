import AppKit
import QuartzCore

/// Window-level reveal / collapse of the launcher.
///
/// Two shapes share the same performance contract: the SwiftUI tree changes
/// exactly once and every intermediate frame is composited by CoreAnimation,
/// not by re-evaluating 165 tiles. The old `withAnimation` show path measured
/// 44–166 ms long frames (8–10% jank in `--open-probe`) on a cold launch.
///   • `fadeShow` / `fadeHide` — macOS 15 Launchpad: pure alpha cross-fade of
///     the window plus the menu-bar cover. The grid never scales or moves.
///   • `show` / `hide` — old centre-out 0.72→1.0 layer transform, kept as a
///     one-variable A/B control (`LAUNCHOS_OPEN_ANIM=scale`).
///
/// `NSHostingView.layer.anchorPoint` is (0, 0), NOT (0.5, 0.5): a plain
/// `CATransform3DMakeScale` would shrink towards the top-left corner. The
/// transform below adds the compensating translation so the centre of the
/// screen stays fixed while the edge expands outward.
enum WindowReveal {
    private static let animationKey = "launchos.windowReveal"

    /// macOS 15 default. `reset` is deliberate: switching back from a `scale`
    /// A/B run must not leave a collapsed transform behind.
    static func fadeShow(window: NSWindow, cover: NSWindow?, duration: TimeInterval) {
        reset(window)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            cover?.animator().alphaValue = 1
        }
    }

    static func fadeHide(window: NSWindow, cover: NSWindow?, duration: TimeInterval,
                         completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
            cover?.animator().alphaValue = 0
        }, completionHandler: completion)
    }

    /// Old centre-out reveal (A/B control). No longer the shipped look.
    static func show(window: NSWindow, cover: NSWindow?,
                     duration: TimeInterval, startScale: CGFloat) {
        let layer = window.contentView?.layer
        let from = centeredScale(startScale, size: revealSize(window, layer))

        // Set the model value to the final state first, then present the
        // intermediate frames. Removing the animation can never snap back.
        setTransform(CATransform3DIdentity, on: layer)
        addAnimation(from: from, to: CATransform3DIdentity,
                     duration: duration, timing: .easeOut, on: layer)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            cover?.animator().alphaValue = 1
        }
    }

    static func hide(window: NSWindow, cover: NSWindow?,
                     duration: TimeInterval, endScale: CGFloat,
                     completion: @escaping () -> Void) {
        let layer = window.contentView?.layer
        let to = centeredScale(endScale, size: revealSize(window, layer))

        // Model value is the collapsed state, so the window stays collapsed
        // after the animation is removed and no full-size frame flashes.
        setTransform(to, on: layer)
        addAnimation(from: CATransform3DIdentity, to: to,
                     duration: duration, timing: .easeIn, on: layer)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
            cover?.animator().alphaValue = 0
        }, completionHandler: completion)
    }

    /// No animation at all (Reduce Motion, or the diagnostic A/B control).
    static func instantShow(window: NSWindow, cover: NSWindow?) {
        window.alphaValue = 1
        cover?.alphaValue = 1
        reset(window)
    }

    static func instantHide(window: NSWindow, cover: NSWindow?) {
        window.alphaValue = 0
        cover?.alphaValue = 0
        reset(window)
    }

    /// Called from `finishHide` before the window is reused. The collapsed
    /// transform must not leak into the next cold or warm reveal.
    static func reset(_ window: NSWindow?) {
        guard let layer = window?.contentView?.layer else { return }
        layer.removeAnimation(forKey: animationKey)
        setTransform(CATransform3DIdentity, on: layer)
    }

    // MARK: - Geometry

    private static func revealSize(_ window: NSWindow, _ layer: CALayer?) -> CGSize {
        let bounds = layer?.bounds.size ?? .zero
        return bounds.width > 1 && bounds.height > 1 ? bounds : window.frame.size
    }

    /// Scale about the centre of `size` with an anchorPoint of (0, 0):
    ///   x' = s·x + cx·(1−s),  y' = s·y + cy·(1−s)
    /// In CATransform3D the translation lives in m41 / m42.
    private static func centeredScale(_ scale: CGFloat, size: CGSize) -> CATransform3D {
        var transform = CATransform3DMakeScale(scale, scale, 1)
        transform.m41 = size.width * 0.5 * (1 - scale)
        transform.m42 = size.height * 0.5 * (1 - scale)
        return transform
    }

    private static func setTransform(_ transform: CATransform3D, on layer: CALayer?) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = transform
        CATransaction.commit()
    }

    private static func addAnimation(from: CATransform3D, to: CATransform3D,
                                     duration: TimeInterval,
                                     timing: CAMediaTimingFunctionName,
                                     on layer: CALayer?) {
        guard let layer, duration > 0.01 else { return }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: from)
        animation.toValue = NSValue(caTransform3D: to)
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: timing)
        layer.add(animation, forKey: animationKey)
    }
}
