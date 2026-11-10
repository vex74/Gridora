import AppKit
import QuartzCore

/// Diagnostic only. Nothing in this file runs unless the app is launched with
/// `--open-probe`. It samples real display-link intervals *during the show
/// animation*, which the paging-focused FrameProbe deliberately skips (it
/// starts recording 1 s after launch).
///
/// Single-variable isolation (the environment variable also works in a normal
/// launch, which is the rollback path):
///   LaunchOS --open-probe                              # macOS 15 cross-fade
///   LAUNCHOS_OPEN_ANIM=scale  LaunchOS --open-probe  # old centre-out reveal
///   LAUNCHOS_OPEN_ANIM=legacy LaunchOS --open-probe  # old SwiftUI transaction
///   LAUNCHOS_OPEN_ANIM=none   LaunchOS --open-probe  # same work, no animation
///
/// Three segments are reported:
///   cold  first show after a cold process launch (app scan, state load,
///         wallpaper decode, first SwiftUI layout and page rasterisation)
///   warm  second show after a hide in the same process (no cold-start cost)
///   idle  steady state, as a machine-noise reference
///
/// Writes /tmp/launchos-open-probe.log then terminates by itself.
enum OpenAnimationMode: String {
    /// macOS 15 Launchpad: window/cover alpha cross-fade. The grid never
    /// scales or moves. Shipped default.
    case fade
    /// Old centre-out reveal on the content layer, kept as a one-variable A/B
    /// control and rollback switch (no SwiftUI transaction).
    case scale
    /// The old `withAnimation { model.isShown = ... }` path, kept as a
    /// reproducible control for A/B and as a one-variable rollback switch.
    case legacy
    /// Instant appear / disappear.
    case none
}

enum OpenAnimationConfig {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--open-probe")

    static let mode: OpenAnimationMode = {
        guard let raw = ProcessInfo.processInfo.environment["LAUNCHOS_OPEN_ANIM"],
              let mode = OpenAnimationMode(rawValue: raw) else { return .fade }
        return mode
    }()

    static var suppressAnimation: Bool { mode == .none }

    static func write(_ text: String) {
        let url = URL(fileURLWithPath: "/tmp/launchos-open-probe.log")
        try? FileManager.default.removeItem(at: url)
        try? (text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

enum OpenProbeAction {
    case hide
    case show
}

/// CADisplayLink retains an @objc target, so keep the selector target a plain
/// NSObject and hop back onto the main actor from the callback — same shape as
/// FrameProbe.ProbeTicker and AppDelegate.GlassFrameSampler.
private final class OpenProbeTicker: NSObject {
    var onTick: ((CFTimeInterval) -> Void)?

    @objc func tick(_ link: CADisplayLink) {
        onTick?(link.timestamp)
    }
}

private enum OpenSegment: String, CaseIterable {
    case cold, warm, idle
}

@MainActor
final class OpenAnimationProbe {
    static let shared = OpenAnimationProbe()

    private let ticker = OpenProbeTicker()
    private var link: CADisplayLink?
    private var previous: CFTimeInterval?
    private var segment: OpenSegment? = .cold
    private var samples: [OpenSegment: [Double]] = [.cold: [], .warm: [], .idle: []]
    private var started = false
    private var drive: ((OpenProbeAction) -> Void)?
    private weak var observed: NSView?
    private var geometry: [String] = []

    /// Called from `showLauncher()` right after the window is ordered front,
    /// so the display link sees the very first animated frame. Later shows in
    /// this process are ignored; `drive` is only used for the warm-up cycle.
    func attach(view: NSView?, drive: @escaping (OpenProbeAction) -> Void) {
        guard OpenAnimationConfig.enabled, !started, let view else { return }
        started = true
        self.drive = drive
        self.observed = view

        let displayLink = view.displayLink(target: ticker,
                                           selector: #selector(OpenProbeTicker.tick(_:)))
        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 60,
                                                                maximum: 120,
                                                                preferred: 120)
        displayLink.add(to: .main, forMode: .common)
        ticker.onTick = { [weak self] timestamp in
            MainActor.assumeIsolated { self?.sample(timestamp) }
        }
        link = displayLink

        // t=0.00  cold show ordered front
        // t=0.80  stop recording (hide transition is not the subject)
        // t=1.20  hide
        // t=1.75  warm show, start recording
        // t=2.55  stop recording
        // t=2.90  steady-state reference
        // t=3.95  write log, quit
        after(0.12) { self.captureMid() }
        after(0.65) { self.captureSettled() }
        after(0.80) { self.segment = nil }
        after(1.20) { self.drive?(.hide) }
        after(1.75) { self.segment = .warm; self.drive?(.show) }
        after(2.55) { self.segment = nil }
        after(2.90) { self.segment = .idle }
        after(3.95) { self.finish() }
    }

    /// Numerical proof of which reveal is running. In `.fade` the content
    /// layer must stay at identity: no scale, no translation, no animation
    /// key. In `.scale` the mid-frame scale is visibly below 1 yet the centre
    /// stays put (anchorPoint is (0, 0), hence the m41/m42 compensation).
    private func captureMid() {
        guard let layer = observed?.layer else { return }
        let t = layer.presentation()?.transform ?? layer.transform
        let w = layer.bounds.width, h = layer.bounds.height
        let centreX = t.m11 * w * 0.5 + t.m41
        let centreY = t.m22 * h * 0.5 + t.m42
        let drift = max(abs(centreX - w * 0.5), abs(centreY - h * 0.5))
        geometry.append(String(format: "midScale=%.4f tx=%.2f ty=%.2f centre=(%.1f,%.1f) centreDrift=%.3f animKeys=%@",
                               t.m11, t.m41, t.m42, centreX, centreY, drift,
                               (layer.animationKeys() ?? []).joined(separator: ",")))
    }

    private func captureSettled() {
        guard let layer = observed?.layer else { return }
        let t = layer.transform
        geometry.append(String(format: "settledScale=%.4f tx=%.2f ty=%.2f anchor=(%.1f,%.1f) bounds=%.0fx%.0f",
                               t.m11, t.m41, t.m42,
                               layer.anchorPoint.x, layer.anchorPoint.y,
                               layer.bounds.width, layer.bounds.height))
    }

    private func sample(_ timestamp: CFTimeInterval) {
        defer { previous = timestamp }
        guard let previous, let segment else { return }
        let dt = (timestamp - previous) * 1000
        // Ignore suspend / debugger stalls; those are not render jank.
        guard dt > 0.5, dt < 250 else { return }
        samples[segment, default: []].append(dt)
    }

    private func after(_ delay: TimeInterval, _ block: @escaping () -> Void) {
        let work = DispatchWorkItem(block: block)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func finish() {
        link?.isPaused = true
        link?.invalidate()

        let all = OpenSegment.allCases.flatMap { samples[$0] ?? [] }
        guard !all.isEmpty else {
            OpenAnimationConfig.write("NO SAMPLES — display link never fired")
            NSApp.terminate(nil)
            return
        }
        let median = percentile(all, 0.50)
        let budget = median < 11.0 ? 12.5 : 25.0
        let hz = median < 11.0 ? 120 : 60

        var out = [
            "PROBE open animation",
            "mode=\(OpenAnimationConfig.mode.rawValue) noAnimation=\(OpenAnimationConfig.suppressAnimation ? 1 : 0)",
            "system=\(ProcessInfo.processInfo.operatingSystemVersionString)",
            "nominal=\(hz)Hz jankBudget=\(budget)ms"
        ]
        out.append(summary("cold ", samples[.cold] ?? [], budget: budget))
        out.append(summary("warm ", samples[.warm] ?? [], budget: budget))
        out.append(summary("idle ", samples[.idle] ?? [], budget: budget))
        out += geometry
        out.append("DONE")
        OpenAnimationConfig.write(out.joined(separator: "\n"))
        NSApp.terminate(nil)
    }

    private func summary(_ label: String, _ values: [Double], budget: Double) -> String {
        guard !values.isEmpty else { return "\(label) no samples" }
        let mean = values.reduce(0, +) / Double(values.count)
        let jank = values.filter { $0 > budget }.count
        let long = values.filter { $0 > 30 }.count
        let pct = Double(jank) / Double(values.count) * 100
        return String(format: "%@ n=%4d mean=%6.2f p50=%6.2f p95=%6.2f p99=%6.2f max=%7.2f jank=%3d (%4.1f%%) long30=%3d",
                      label, values.count, mean,
                      percentile(values, 0.50), percentile(values, 0.95),
                      percentile(values, 0.99), values.max() ?? 0, jank, pct, long)
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count) * p)))
        return sorted[index]
    }
}
