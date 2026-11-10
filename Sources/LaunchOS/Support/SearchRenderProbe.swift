import Foundation

/// Diagnostics only. Compiled into the shipping build but inert unless the
/// `--search-query-probe` harness flips `enabled`.
///
/// `SearchOverlay` calls `note` from its `results` computed property, so the
/// snapshot records what the *view* actually computed during a body evaluation.
/// That is deliberately different from `LauncherModel.searchResults`, which
/// a probe can read directly: comparing the two separates "the model
/// recomputed" from "SwiftUI re-rendered the results panel".
@MainActor
enum SearchRenderProbe {
    static var enabled = false

    static private(set) var evaluations = 0
    static private(set) var lastQuery = ""
    static private(set) var lastCount = -1
    static private(set) var lastName = "-"

    static func note(query: String, count: Int, firstName: String) {
        guard enabled else { return }
        evaluations += 1
        lastQuery = query
        lastCount = count
        lastName = firstName
    }

    static func reset() {
        evaluations = 0
        lastQuery = ""
        lastCount = -1
        lastName = "-"
    }

    static var snapshot: String {
        "evals=\(evaluations) query=\(lastQuery.debugDescription) "
            + "renderedCount=\(lastCount) first=\(lastName)"
    }
}
