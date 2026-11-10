import Foundation

/// Backwards-compatible name for the first recordable shortcut. All chord
/// logic now lives in `Model/KeyChord.swift`, which also owns the launcher,
/// previous-page and next-page shortcuts.
typealias SearchHotKey = KeyChord
