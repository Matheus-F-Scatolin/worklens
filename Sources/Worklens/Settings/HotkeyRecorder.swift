import AppKit
import Carbon.HIToolbox
import SwiftUI
import WorklensCore

// MARK: - The recorder

/// Click or press Space, press a combination, done. The replacement for
/// `KeyboardShortcuts.Recorder` — see `GlobalHotkey.swift` for why that dependency is gone.
///
/// An AppKit control rather than a SwiftUI `onKeyPress`, because the point is to catch the raw
/// `keyDown` **including** the modifiers and *without* letting it reach the menu system: a
/// recorder that fires ⌘Q while you are trying to bind it is not a recorder.
struct HotkeyRecorder: NSViewRepresentable {
    var spec: HotkeySpec?
    @Binding var isRecording: Bool
    /// What VoiceOver calls it: "Pause or resume shortcut", "Open Worklens shortcut".
    var label = "Pause or resume shortcut"
    var onRecord: (HotkeySpec) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onRecord = onRecord
        view.onRecordingChanged = { isRecording = $0 }
        view.spec = spec
        view.label = label
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.onRecord = onRecord
        view.spec = spec
        view.label = label
    }

    /// #154: an `NSControl` with a role, a label and a value, reachable and operable from the
    /// keyboard alone. It used to be a plain `NSView` that only `mouseDown` could start, which
    /// left the one global control the app has unusable to VoiceOver and to Full Keyboard
    /// Access — on a kill switch, of all things.
    final class RecorderView: NSControl {
        var onRecord: ((HotkeySpec) -> Void)?
        var onRecordingChanged: ((Bool) -> Void)?
        var label = "Pause or resume shortcut"

        var spec: HotkeySpec? {
            didSet {
                guard spec != oldValue else { return }
                cachedKeyName = nil
                invalidateIntrinsicContentSize()
                needsDisplay = true
                // Covers both a fresh recording and Reset: either way the value a screen reader
                // last read is no longer what the control says.
                NSAccessibility.post(element: self, notification: .valueChanged)
            }
        }

        private var listening = false
        /// #286: whether it is waiting for a combination — the Settings page leaves Esc alone
        /// while it is, because Esc is how a recording is cancelled.
        var isListening: Bool { listening }
        /// `HotkeySpec.display` asks Text Input Services for the letter the active layout puts on
        /// the key, which is far too much to do inside `draw`.
        private var cachedKeyName: String?
        private var layoutObserver: NSObjectProtocol?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            focusRingType = .default
            // Switching to AZERTY while Settings is open changes the letter on the key; the
            // recorder should say so without being clicked.
            layoutObserver = NotificationCenter.default.addObserver(
                forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.cachedKeyName = nil
                    self.invalidateIntrinsicContentSize()
                    self.needsDisplay = true
                }
            }
        }

        required init?(coder: NSCoder) { nil }

        deinit {
            if let layoutObserver { NotificationCenter.default.removeObserver(layoutObserver) }
        }

        // MARK: What it says

        /// `⌥⇧P`, or "not set" when nothing is bound. The same string the view paints.
        private var valueText: String {
            guard let spec else { return "not set" }
            if let cachedKeyName { return cachedKeyName }
            let text = spec.display
            cachedKeyName = text
            return text
        }

        private var drawnText: String {
            if listening { return "Type a shortcut" }
            return spec == nil ? "Click to set" : valueText
        }

        private var textAttributes: [NSAttributedString.Key: Any] {
            [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: listening ? NSColor(ReaderTheme.accentInk) : NSColor(ReaderTheme.text),
                .kern: listening ? 0 : 0.8,
            ]
        }

        // MARK: Accessibility

        override func accessibilityRole() -> NSAccessibility.Role? { .button }
        override func accessibilityLabel() -> String? { label }
        override func accessibilityValue() -> Any? { valueText }
        override func accessibilityHelp() -> String? {
            "Press Space to record a new combination; Escape cancels"
        }

        override func isAccessibilityElement() -> Bool { true }

        override func accessibilityPerformPress() -> Bool {
            startListening()
            return true
        }

        // MARK: Keyboard and mouse

        override var acceptsFirstResponder: Bool { true }
        override var canBecomeKeyView: Bool { true }

        override func mouseDown(with event: NSEvent) { startListening() }

        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok { needsDisplay = true }
            return ok
        }

        override func resignFirstResponder() -> Bool {
            stopListening()
            return true
        }

        override func keyDown(with event: NSEvent) {
            // Focused but idle: Space and Return do what a click does. Before #154 they fell
            // through here and a keyboard user could never start the recorder at all.
            guard listening else {
                let bare = event.modifierFlags
                    .intersection(.deviceIndependentFlagsMask)
                    .isEmpty
                if bare, event.keyCode == UInt16(kVK_Space) || event.keyCode == UInt16(kVK_Return) {
                    startListening()
                    return
                }
                return super.keyDown(with: event)
            }
            // ⎋ leaves the binding alone — the escape hatch from a recorder that is listening.
            if event.keyCode == UInt16(kVK_Escape) {
                stopListening()
                return
            }
            guard let recorded = HotkeySpec(event: event) else {
                NSSound.beep()  // no modifier: it would swallow that key in every app
                return
            }
            listening = false
            onRecordingChanged?(false)
            spec = recorded
            onRecord?(recorded)
            // Focus stays here — a keyboard user hears the new value and can record again
            // without tabbing back. It used to be dropped, which is fine for a mouse and
            // useless for anything else.
            needsDisplay = true
        }

        /// `flagsChanged` is swallowed on purpose: a bare ⌥ is not a shortcut, and letting it
        /// through would record one the instant a modifier went down.
        override func flagsChanged(with event: NSEvent) {}

        private func startListening() {
            guard !listening else { return }
            listening = true
            onRecordingChanged?(true)
            // Guarded: making an already-first responder first again would resign it first, and
            // `resignFirstResponder` is what stops listening.
            if window?.firstResponder !== self { window?.makeFirstResponder(self) }
            needsDisplay = true
        }

        private func stopListening() {
            guard listening else { return }
            listening = false
            onRecordingChanged?(false)
            needsDisplay = true
        }

        // MARK: Drawing

        /// Wide enough for the text it holds, at the system font size, rather than a fixed 110
        /// points that a long combination or a large-text setting overflows.
        override var intrinsicContentSize: NSSize {
            let candidates = [drawnText, "Type a shortcut", "Click to set"]
            let width = candidates
                .map { ($0 as NSString).size(withAttributes: textAttributes).width }
                .max() ?? 0
            let height = ("Ag" as NSString).size(withAttributes: textAttributes).height
            return NSSize(
                width: max(74, ceil(width) + 22),
                height: max(24, ceil(height) + 8)
            )
        }

        override var focusRingMaskBounds: NSRect { bounds }

        override func drawFocusRingMask() {
            let radius = ReaderTheme.Radius.segment
            NSBezierPath(
                roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius
            ).fill()
        }

        override func draw(_ dirtyRect: NSRect) {
            // #286: the prototype's key cap — the field colour, a hairline and a one-point line
            // under it — and the terracotta outline while it listens.
            let radius = ReaderTheme.Radius.segment
            let cap = bounds.insetBy(dx: 1, dy: 1).offsetBy(dx: 0, dy: 0.5)
            let shadow = NSBezierPath(roundedRect: cap.offsetBy(dx: 0, dy: -1), xRadius: radius, yRadius: radius)
            NSColor(ReaderTheme.line).setFill()
            shadow.fill()
            let rounded = NSBezierPath(roundedRect: cap, xRadius: radius, yRadius: radius)
            // The accent stroke is the "listening" cue; the focus ring is drawn separately by
            // AppKit from `drawFocusRingMask`, so the two states read differently.
            NSColor(listening ? ReaderTheme.accent : ReaderTheme.line).setStroke()
            NSColor(ReaderTheme.field).setFill()
            rounded.fill()
            rounded.lineWidth = 1
            rounded.stroke()

            let text = drawnText
            let attributes = textAttributes
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(
                at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                withAttributes: attributes
            )
        }
    }
}
