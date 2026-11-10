import AppKit
import QuartzCore

/// Diagnostic only. Nothing in this file runs unless the app is launched with
/// `--fps-probe`. It records *real* display-link intervals while the launcher
/// renders, then writes /tmp/launchos-fps.log and terminates.
///
/// Switches for measurement and for a safe rollback:
///
///   LAUNCHOS_NO_DRIFT=1       keep the artwork, stop both ambient animations
///   LAUNCHOS_FLAT_BACKDROP=1  replace the whole backdrop with a flat color
///   LAUNCHOS_NO_RASTER=1      disable page rasterisation (interaction
///                             rollback switch; expect ~12% paging jank)
///   LAUNCHOS_NO_LIVE_REFLOW=1 disable the drag-time make-way preview
///                             (single-variable A/B / rollback switch)
///   LAUNCHOS_DRAG_FPS=1       synthesise a 120 Hz pointer stream instead of
///                             page turns, so the make-way preview can be
///                             measured against the no-reflow control
///
/// Typical run:
///   LaunchOS --fps-probe
///   LAUNCHOS_NO_DRIFT=1 LaunchOS --fps-probe
///   LAUNCHOS_FLAT_BACKDROP=1 LaunchOS --fps-probe
enum ProbeConfig {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--fps-probe")
    static let noDrift = ProcessInfo.processInfo.environment["LAUNCHOS_NO_DRIFT"] == "1"
    static let flatBackdrop = ProcessInfo.processInfo.environment["LAUNCHOS_FLAT_BACKDROP"] == "1"
    static let noRaster = ProcessInfo.processInfo.environment["LAUNCHOS_NO_RASTER"] == "1"
    /// Measured rollback for the collapsed folder icon's glass. The icon lives
    /// inside the rasterised paging path, so this stays available as a single
    /// variable A/B switch even after the feature ships enabled by default.
    static let folderIconNoGlass =
        ProcessInfo.processInfo.environment["LAUNCHOS_FOLDER_ICON_NOGLASS"] == "1"
    /// `glassEffect` is flattened away inside PageSlot.drawingGroup(). The
    /// folder plates therefore live in the page's background, OUTSIDE the
    /// raster, and this env is the single-variable A/B / rollback switch.
    static let folderIconPlate =
        ProcessInfo.processInfo.environment["LAUNCHOS_FOLDER_ICON_NOPLATE"] != "1"
    /// macOS 15 reflows the other icons around a dragged tile while the
    /// pointer is over a gap, but freezes them when the artwork sits on a
    /// merge target. Only the low-frequency insertion slot is published, so
    /// this stays outside the 120 Hz pointer stream. Kept as a one-variable
    /// rollback because it invalidates a rasterised page on every cell crossing.
    static let liveReflow =
        ProcessInfo.processInfo.environment["LAUNCHOS_NO_LIVE_REFLOW"] != "1"
    static let dragFPS =
        ProcessInfo.processInfo.environment["LAUNCHOS_DRAG_FPS"] == "1"
    /// `LAUNCHOS_DRAG_FAST=1` exaggerates the pointer speed so one cell is
    /// crossed every frame — a worst-case stress test, not a realistic drag.
    /// Default is 2 pt/frame, the speed of a real 120 Hz mouse move.
    static let dragFast =
        ProcessInfo.processInfo.environment["LAUNCHOS_DRAG_FAST"] == "1"
    /// `LAUNCHOS_FOLDER_FPS=1` opens a multi-page folder and turns its pages
    /// instead of the main pager. v1.5 slides folder pages, which renders up
    /// to three 3 × 3 pages at once — a cost that must be measured, not
    /// assumed.
    static let folderFPS =
        ProcessInfo.processInfo.environment["LAUNCHOS_FOLDER_FPS"] == "1"
    /// v1.6: the selection/hover highlight now derives its radius, fill and
    /// glow from the one global glass group. This is the single-variable
    /// rollback used by the A/B (back to the old hard-coded white rounded
    /// rectangle on all three surfaces).
    static let selectionGlassDisabled =
        ProcessInfo.processInfo.environment["LAUNCHOS_NO_SELECTION_GLASS"] == "1"

    static func write(_ text: String) {
        let url = URL(fileURLWithPath: "/tmp/launchos-fps.log")
        try? FileManager.default.removeItem(at: url)
        try? (text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

/// CADisplayLink retains an @objc target, so keep the selector target a plain
/// NSObject and hop back onto the main actor from the callback.
private final class ProbeTicker: NSObject {
    var onTick: ((CFTimeInterval) -> Void)?

    @objc func tick(_ link: CADisplayLink) {
        onTick?(link.timestamp)
    }
}

@MainActor
final class FrameProbe {
    static let shared = FrameProbe()

    private let ticker = ProbeTicker()
    private var link: CADisplayLink?
    private var previous: CFTimeInterval = 0
    private var recording = false
    private var inPaging = false
    private var idleSamples: [Double] = []      // milliseconds
    private var pagingSamples: [Double] = []
    private var onFrame: ((Int) -> Void)?
    private var frameIndex = 0

    /// `drive` is called five times to produce real page transitions. With
    /// `onFrame` the measurement window instead replays a pointer stream once
    /// per display frame, which is the only way to measure a drag-time
    /// reflow against the same binary with the reflow switched off.
    func start(view: NSView,
               drive: @escaping () -> Void,
               onFrame: ((Int) -> Void)? = nil) {
        guard ProbeConfig.enabled else { return }
        self.onFrame = onFrame

        let displayLink = view.displayLink(target: ticker,
                                           selector: #selector(ProbeTicker.tick(_:)))
        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 60,
                                                                maximum: 120,
                                                                preferred: 120)
        displayLink.add(to: .main, forMode: .common)
        ticker.onTick = { [weak self] timestamp in
            MainActor.assumeIsolated { self?.sample(timestamp) }
        }
        link = displayLink

        // 0.0–1.0 s  warm-up (app scan, wallpaper load, first layout)
        // 1.0–2.0 s  static frame: cost of the ambient backdrop alone
        // 2.0–6.0 s  one page transition every 0.8 s
        after(1.0) { self.recording = true }
        after(2.0) { self.inPaging = true }
        for i in 0..<5 {
            after(2.0 + Double(i) * 0.8) { drive() }
        }
        after(6.2) { self.finish() }
    }

    private func sample(_ timestamp: CFTimeInterval) {
        guard recording else {
            previous = timestamp
            return
        }
        guard previous > 0 else {
            previous = timestamp
            return
        }
        let dt = (timestamp - previous) * 1000
        previous = timestamp
        // Ignore suspend / debugger stalls; those are not render jank.
        guard dt > 0.5, dt < 250 else { return }
        if inPaging {
            pagingSamples.append(dt)
            frameIndex += 1
            onFrame?(frameIndex)
        } else {
            idleSamples.append(dt)
        }
    }

    private func after(_ delay: TimeInterval, _ block: @escaping () -> Void) {
        // Same pattern as the rest of the app: a DispatchWorkItem avoids the
        // @Sendable closure requirement of asyncAfter(execute:).
        let work = DispatchWorkItem(block: block)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func finish() {
        link?.isPaused = true
        link?.invalidate()

        let all = idleSamples + pagingSamples
        guard !all.isEmpty else {
            ProbeConfig.write("NO SAMPLES — display link never fired")
            NSApp.terminate(nil)
            return
        }
        let median = percentile(all, 0.50)
        // 1.5× the nominal frame time is the jank threshold.
        let budget = median < 11.0 ? 12.5 : 25.0
        let hz = median < 11.0 ? 120 : 60

        let mode = ProbeConfig.noRaster ? "no-raster"
            : ProbeConfig.flatBackdrop ? "flat"
            : ProbeConfig.noDrift ? "no-drift" : "baseline"
        var out = [
            "mode=\(mode) noDrift=\(ProbeConfig.noDrift ? 1 : 0)"
                + " flat=\(ProbeConfig.flatBackdrop ? 1 : 0)"
                + " noRaster=\(ProbeConfig.noRaster ? 1 : 0)"
                + " dragFPS=\(ProbeConfig.dragFPS ? 1 : 0)"
                + " folderFPS=\(ProbeConfig.folderFPS ? 1 : 0)"
                + " liveReflow=\(ProbeConfig.liveReflow ? 1 : 0)",
            "nominal=\(hz)Hz jankBudget=\(budget)ms"
        ]
        out.append(summary("idle  ", idleSamples, budget: budget))
        out.append(summary("paging", pagingSamples, budget: budget))
        ProbeConfig.write(out.joined(separator: "\n"))
        NSApp.terminate(nil)
    }

    private func summary(_ label: String, _ samples: [Double], budget: Double) -> String {
        guard !samples.isEmpty else { return "\(label) no samples" }
        let mean = samples.reduce(0, +) / Double(samples.count)
        let jank = samples.filter { $0 > budget }.count
        let pct = Double(jank) / Double(samples.count) * 100
        return String(format: "%@ n=%4d mean=%6.2f p50=%6.2f p95=%6.2f p99=%6.2f max=%7.2f jank=%3d (%4.1f%%)",
                      label, samples.count, mean,
                      percentile(samples, 0.50), percentile(samples, 0.95),
                      percentile(samples, 0.99), samples.max() ?? 0, jank, pct)
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count) * p)))
        return sorted[index]
    }
}

/// Opt-in wheel tracing. Nothing is allocated or written unless the app is
/// launched with `LAUNCHOS_WHEEL_LOG=1`:
///
///   LAUNCHOS_WHEEL_LOG=1 LaunchOS   # scroll a few notches, then read the log
///
/// The log records the raw event fields and the paging decision, so a report
/// of "one notch does nothing" can be diagnosed from real hardware instead of
/// guessed from the code.
enum WheelDiagnostics {
    static let enabled = ProcessInfo.processInfo.environment["LAUNCHOS_WHEEL_LOG"] == "1"

    static func reset() {
        guard enabled else { return }
        try? FileManager.default.removeItem(atPath: "/tmp/launchos-wheel.log")
    }

    static func log(_ text: String) {
        guard enabled else { return }
        let line = String(format: "%.4f  ", CACurrentMediaTime()) + text + "\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/launchos-wheel.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
