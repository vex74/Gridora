import AppKit
import SwiftUI

/// Diagnostic: `LaunchOS --panel-visibility-probe` answers "why can't I see
/// the settings?" with numbers instead of a guess. It samples the AppKit view
/// tree with settings closed and open, on two settings pages, and records:
///   - window / cover geometry and alpha
///   - every NSButton / NSSlider / NSScrollView frame, alpha and hidden flag
///   - SwiftUI's ScrollView document height vs its visible rect
///   - the real grid metrics at the user's saved icon scale
/// Screen capture is unavailable in this environment, so no screenshot is
/// attempted. Off by default; writes /tmp/launchos-panel-visibility.log and
/// terminates itself.
enum PanelVisibilityProbe {
    static func startIfNeeded(model: LauncherModel,
                              window: NSWindow?,
                              cover: NSWindow?) {
        guard ProcessInfo.processInfo.arguments.contains("--panel-visibility-probe") else { return }
        let logPath = "/tmp/launchos-panel-visibility.log"
        try? FileManager.default.removeItem(atPath: logPath)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            var lines: [String] = [
                "PROBE panel visibility",
                "system=\(ProcessInfo.processInfo.operatingSystemVersionString)",
                "active=\(NSApp.isActive) keyWindow=\(window?.isKeyWindow ?? false)"
            ]

            func f(_ v: CGFloat) -> String { String(format: "%.1f", v) }

            // Nested functions do not inherit the enclosing Task's @MainActor
            // isolation, so annotate every helper that touches model/NSView.
            @MainActor func windowLines(_ tag: String, _ w: NSWindow?) {
                guard let w else { lines.append("\(tag) window=nil"); return }
                lines.append("\(tag) window frame=\(f(w.frame.origin.x)),\(f(w.frame.origin.y))"
                    + " \(f(w.frame.width))x\(f(w.frame.height))"
                    + " alpha=\(f(w.alphaValue)) visible=\(w.isVisible)"
                    + " level=\(w.level.rawValue)"
                    + " content=\(f(w.contentView?.bounds.width ?? 0))x\(f(w.contentView?.bounds.height ?? 0))"
                    + " layerOpacity=\(f(CGFloat(w.contentView?.layer?.opacity ?? 0)))")
            }

            @MainActor func collect(_ view: NSView?, into out: inout [NSView]) {
                guard let view else { return }
                out.append(view)
                for sub in view.subviews { collect(sub, into: &out) }
            }

            @MainActor func controlLines(_ tag: String, root: NSView?) {
                var views: [NSView] = []
                collect(root, into: &views)
                let interesting = views.filter {
                    $0 is NSButton || $0 is NSSlider || $0 is NSScrollView
                        || $0 is NSTextField || $0 is NSClipView
                        || String(describing: type(of: $0)).contains("Hosting")
                }
                lines.append("\(tag) treeTotal=\(views.count) controls=\(interesting.count)")
                for v in interesting.prefix(28) {
                    let cls = String(describing: type(of: v))
                    let rect = v.convert(v.bounds, to: nil)
                    var extra = ""
                    if let s = v as? NSSlider {
                        extra = " value=\(String(format: "%.3f", s.doubleValue))"
                            + " min=\(String(format: "%.2f", s.minValue))"
                            + " max=\(String(format: "%.2f", s.maxValue))"
                    } else if let b = v as? NSButton {
                        extra = " title=\(b.title.debugDescription) tip=\((b.toolTip ?? "").debugDescription)"
                    } else if let t = v as? NSTextField {
                        extra = " str=\(t.stringValue.prefix(24).debugDescription)"
                    }
                    if let scroll = v as? NSScrollView {
                        let doc = scroll.documentView?.frame.size ?? .zero
                        let vis = scroll.documentVisibleRect.size
                        extra = " doc=\(f(doc.width))x\(f(doc.height))"
                            + " visible=\(f(vis.width))x\(f(vis.height))"
                            + " clipped=\(f(doc.height - vis.height))"
                    }
                    lines.append("  \(tag) \(cls)"
                        + " at=\(f(rect.origin.x)),\(f(rect.origin.y))"
                        + " \(f(rect.width))x\(f(rect.height))"
                        + " alpha=\(f(v.alphaValue))"
                        + " layerOpacity=\(f(CGFloat(v.layer?.opacity ?? 0)))"
                        + " hidden=\(v.isHidden)" + extra)
                }
            }

            @MainActor func metricsLines(_ tag: String) {
                let m = model.metrics
                lines.append("\(tag) METRICS scale=\(String(format: "%.4f", model.settings.iconScale))"
                    + " cols=\(m.cols) rows=\(m.rows)"
                    + " area=\(f(m.size.width))x\(f(m.size.height))"
                    + " cellW=\(f(m.cellW)) cellH=\(f(m.cellH))"
                    + " iconSize=\(f(m.iconSize))"
                    + " insets=T\(f(m.insets.top)) L\(f(m.insets.left)) B\(f(m.insets.bottom)) R\(f(m.insets.right))"
                    + " page=\(model.settingsPage.rawValue)"
                    + " settingsOpen=\(model.settingsOpen) searchOpen=\(model.searchOpen)")
            }

            @MainActor func layoutAssertion(_ tag: String) {
                let contentWidth = window?.contentView?.bounds.width ?? 0
                // LauncherView pads the VStack by 26 pt on each side.
                let expected = contentWidth - 52
                let actual = model.metrics.size.width
                lines.append("\(tag) ASSERT contentWidth=\(f(contentWidth))"
                    + " expectedPagerWidth=\(f(expected))"
                    + " actualPagerWidth=\(f(actual))"
                    + " drift=\(f(actual - expected))"
                    + " \(abs(actual - expected) < 1.0 ? "PASS" : "FAIL-inflated")")
            }

            @MainActor func layerOpacityLines(_ tag: String, root: NSView?) {
                var total = 0, zero = 0, dim = 0
                var samples: [String] = []
                func walk(_ layer: CALayer) {
                    total += 1
                    let o = layer.opacity
                    if o < 0.01 {
                        zero += 1
                        if samples.count < 5 {
                            samples.append("\(String(describing: type(of: layer)))"
                                + "@\(f(layer.frame.width))x\(f(layer.frame.height))")
                        }
                    } else if o < 0.9 { dim += 1 }
                    for sub in layer.sublayers ?? [] { walk(sub) }
                }
                if let l = root?.layer { walk(l) }
                lines.append("\(tag) LAYERS total=\(total) zeroOpacity=\(zero)"
                    + " dim=\(dim) zeroSamples=[\(samples.joined(separator: ","))]")
            }

            // A. Baseline: settings closed, top bar on screen.
            model.settingsOpen = false
            model.hiddenOpen = false
            model.openFolderID = nil
            model.closeSearch()
            model.settingsPage = .general
            try? await Task.sleep(nanoseconds: 350_000_000)
            windowLines("CLOSED", window)
            windowLines("CLOSED-COVER", cover)
            metricsLines("CLOSED")
            layoutAssertion("CLOSED")
            controlLines("CLOSED", root: window?.contentView)
            layerOpacityLines("CLOSED", root: window?.contentView)

            // B. Open settings (general page).
            model.showSettings()
            try? await Task.sleep(nanoseconds: 550_000_000)
            windowLines("OPEN", window)
            metricsLines("OPEN")
            layoutAssertion("OPEN")
            controlLines("OPEN", root: window?.contentView)

            // C. Layout page: this is where the icon-size slider lives and it
            //    is the tallest page (needs the ScrollView to be reachable).
            model.settingsPage = .layout
            try? await Task.sleep(nanoseconds: 450_000_000)
            metricsLines("LAYOUT")
            layoutAssertion("LAYOUT")
            controlLines("LAYOUT", root: window?.contentView)

            // D. Sweep the icon slider while the panel is open, so a scale that
            //    makes the panel disappear would show up in the tree dump.
            for s in [0.78, 1.0, 1.4] {
                model.settings.iconScale = s
                try? await Task.sleep(nanoseconds: 160_000_000)
                metricsLines("SWEEP")
                var views: [NSView] = []
                collect(window?.contentView, into: &views)
                let scrolls = views.compactMap { $0 as? NSScrollView }
                lines.append("  SWEEP scrollViews=\(scrolls.count)"
                    + " docHeights=[\(scrolls.map { f($0.documentView?.frame.height ?? 0) }.joined(separator: ","))]"
                    + " visibleHeights=[\(scrolls.map { f($0.documentVisibleRect.height) }.joined(separator: ","))]"
                    + " buttons=\(views.filter { $0 is NSButton }.count)"
                    + " sliders=\(views.filter { $0 is NSSlider }.count)")
            }

            lines.append("DONE")
            try? (lines.joined(separator: "\n") + "\n")
                .write(toFile: logPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}
