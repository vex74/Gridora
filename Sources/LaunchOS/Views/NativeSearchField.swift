import AppKit
import SwiftUI

/// AppKit-backed search field. Search is opened by typing a letter over the
/// icon grid, and `handleKey` puts that first character straight into
/// `model.query` before any field editor exists. With SwiftUI's `TextField` +
/// `@FocusState` the handoff is asynchronous: the next keystroke either goes
/// to the window (and is dropped) or lands while the injected text is still
/// selected (and replaces it). `--search-realuse-probe` measured exactly that:
/// `c` -> `a` lost, `c` -> `w` became `w`, delete sometimes did nothing.
///
/// Owning firstResponder in AppKit makes the editing session deterministic:
/// the field becomes first responder as soon as it moves into the window, the
/// caret is explicitly placed after the injected text, and text changes are
/// published to the model from the delegate (never from a SwiftUI onChange
/// that fires a second `objectWillChange` in the middle of editing).
struct NativeSearchField: NSViewRepresentable {
    @EnvironmentObject var model: LauncherModel
    @Binding var editing: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, editing: $editing)
    }

    func makeNSView(context: Context) -> LaunchOSSearchTextField {
        let field = LaunchOSSearchTextField()
        field.configure()
        field.delegate = context.coordinator
        context.coordinator.field = field
        // Seed the field from the model only at creation time. Afterwards the
        // field is the source of truth; `updateNSView` must never write into
        // it or a Chinese IME commit gets rolled back to stale query text.
        field.stringValue = model.query
        model.searchField = field
        let coordinator = context.coordinator
        field.owner = model
        field.onTextSync = { [weak coordinator, weak field] text in
            MainActor.assumeIsolated {
                guard let model = coordinator?.model, model.searchField === field else { return }
                model.adoptFieldText(text)
            }
        }
        field.startFocusGuard()
        // Claiming first responder inside viewDidMoveToWindow happens while
        // SwiftUI is still installing the hierarchy and steals the key status
        // from the launcher window. One runloop later the window is settled;
        // updateNSView below is the steady-state guard.
        DispatchQueue.main.async { [weak field] in
            field?.claimFocus()
        }
        return field
    }

    func updateNSView(_ field: LaunchOSSearchTextField, context: Context) {
        context.coordinator.model = model
        // No model -> field write here on purpose. External writes go through
        // `LauncherModel.setSearchText`, which updates the field directly.
        // SwiftUI can hand first responder back to the window when the
        // surrounding tree recomputes (e.g. results become empty), so keep
        // reclaiming it while search is open.
        if model.searchOpen { field.claimFocus() }
    }

    static func dismantleNSView(_ field: LaunchOSSearchTextField,
                                coordinator: Coordinator) {
        field.stopFocusGuard()
        field.onTextSync = nil
        MainActor.assumeIsolated {
            if coordinator.model?.searchField === field {
                coordinator.model?.searchField = nil
            }
        }
        // Retire the shared field editor when search closes. Leaving it as
        // first responder makes the key monitor treat later letters as text
        // editing, so search never reopens and the old results stay on screen.
        // Only retire the editor when search really closed. SwiftUI can
        // dismantle and recreate the field while recomputing results; doing
        // this unconditionally would pull focus out from under live typing.
        let searchStillOpen = MainActor.assumeIsolated {
            coordinator.model?.searchOpen ?? false
        }
        if !searchStillOpen, field.ownsFirstResponder {
            field.window?.makeFirstResponder(nil)
        }
        field.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        weak var model: LauncherModel?
        var editing: Binding<Bool>
        weak var field: LaunchOSSearchTextField?

        init(model: LauncherModel, editing: Binding<Bool>) {
            self.model = model
            self.editing = editing
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let text = field.stringValue
            MainActor.assumeIsolated {
                // Publish every change, including the final IME commit. The
                // earlier `hasMarkedText()` guard could drop the only
                // notification that arrives after a Chinese candidate is
                // selected, leaving `query` at the previous ASCII word while
                // the field showed the new Chinese text.
                model?.adoptFieldText(text)
            }
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            MainActor.assumeIsolated { editing.wrappedValue = true }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            MainActor.assumeIsolated { editing.wrappedValue = false }
        }
    }
}

/// Plain single-line NSTextField styled to match the surrounding SwiftUI
/// chrome. `viewDidMoveToWindow` is the earliest reliable point at which the
/// hosting window exists, so focus is claimed synchronously there instead of
/// being requested from an async SwiftUI focus state write.
final class LaunchOSSearchTextField: NSTextField {
    override var acceptsFirstResponder: Bool { true }

    /// A closing SearchOverlay can stay in the hierarchy during its opacity
    /// transition. Its 0.1 s timer and the newly opened field would then both
    /// publish text to `model.query`, pulling it back to stale values one
    /// keystroke later (measured: 4/4 runs of --search-realuse-probe lost a
    /// character on the second search session). Only the field currently
    /// registered on the model may drive focus or publish text.
    weak var owner: LauncherModel?
    var isActiveField: Bool { owner?.searchField === self }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The window is now installed, but claiming focus synchronously here
        // (while SwiftUI is still assembling the hierarchy) can steal the key
        // status. One runloop later is both early enough for fast typists and
        // late enough to be safe.
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.claimFocus()
        }
    }

    func configure() {
        isEditable = true
        isSelectable = true
        isBordered = false
        isBezeled = false
        drawsBackground = false
        refusesFirstResponder = false
        focusRingType = .none
        textColor = .white
        font = NSFont.systemFont(ofSize: 14, weight: .regular)
        placeholderAttributedString = NSAttributedString(
            string: "搜索 App（名称或拼音）",
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.32),
                .font: NSFont.systemFont(ofSize: 14, weight: .regular)
            ])
        lineBreakMode = .byTruncatingTail
        cell?.isScrollable = true
        cell?.wraps = false
    }

    /// Focus is claimed after the view has been installed, and re-claimed from
    /// `updateNSView` whenever SwiftUI recomputes the surrounding tree.
    func claimFocus() {
        guard isActiveField, let window, window.isVisible, !ownsFirstResponder else { return }
        window.makeFirstResponder(self)
    }

    /// Fallback for input methods that commit text into the shared field
    /// editor without delivering `controlTextDidChange`. `--search-ime-probe`
    /// measured `field="广告"` while `query` stayed `"hid"`, so the results
    /// froze on Hiddify. Runs only while the search field exists.
    var onTextSync: ((String) -> Void)?

    /// Focus guard plus a text reconciliation tick. Both are no-ops while
    /// nothing changed, so this costs one cheap comparison per tick and only
    /// lives during an open search (never on the paging path).
    private var focusGuard: Timer?

    func startFocusGuard() {
        stopFocusGuard()
        focusGuard = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActiveField else { return }
                self.claimFocus()
                self.onTextSync?(self.stringValue)
            }
        }
    }

    func stopFocusGuard() {
        focusGuard?.invalidate()
        focusGuard = nil
    }

    override func becomeFirstResponder() -> Bool {
        let granted = super.becomeFirstResponder()
        if granted {
            (currentEditor() as? NSTextView)?.insertionPointColor = .white
            moveCaretToEnd()
        }
        return granted
    }

    /// The injected first character must not stay selected, otherwise the
    /// next keystroke replaces it instead of appending.
    func moveCaretToEnd() {
        guard let editor = currentEditor() as? NSTextView else { return }
        let end = (stringValue as NSString).length
        if editor.selectedRange.location != end || editor.selectedRange.length != 0 {
            editor.selectedRange = NSRange(location: end, length: 0)
        }
    }

    /// An NSTextField edits through the window's shared field editor, so the
    /// real first responder is an NSTextView rather than the field itself.
    var ownsFirstResponder: Bool {
        guard let window else { return false }
        if let editor = currentEditor() as? NSResponder { return window.firstResponder === editor }
        return window.firstResponder === self
    }
}
