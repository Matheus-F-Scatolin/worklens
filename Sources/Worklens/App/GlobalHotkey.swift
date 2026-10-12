import AppKit
import Carbon.HIToolbox
import Foundation
import WorklensCore

/// One global hotkey, as a value: a virtual key code plus Carbon modifier bits.
///
/// Stored in `app_state` as JSON rather than in `UserDefaults`, so everything Worklens knows
/// about you — including the key you press to stop it looking — lives in the one folder
/// `PRIVACY.md` names.
struct HotkeySpec: Codable, Equatable, Sendable {
    /// A `kVK_*` virtual key code. Layout-independent: it is a physical key, not a character.
    var keyCode: UInt32
    /// Carbon modifier mask (`optionKey`, `shiftKey`, `cmdKey`, `controlKey`).
    var modifiers: UInt32

    /// `⌥⇧P` — the pause hotkey out of the box. Chosen because macOS itself does not use it and
    /// no common app does either.
    static let defaultPause = HotkeySpec(
        keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(optionKey | shiftKey)
    )

    /// `⌥⇧W` — the open-Worklens hotkey out of the box (#252). Picked on the same test the
    /// pause default was: nothing on the machine already owns it.
    static let defaultOpen = HotkeySpec(
        keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(optionKey | shiftKey)
    )

    /// `app_state` key holding the user's choice, if they made one.
    static let pauseKey = "pause_hotkey"
    /// The same, for the hotkey that opens Worklens.
    static let openKey = "open_hotkey"

    // MARK: Display

    /// `⌥⇧P` — what Settings shows and what the notification says.
    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + HotkeySpec.keyName(keyCode)
    }

    /// True when there is at least one modifier. A bare letter would swallow that key in every
    /// app on the Mac, which is not a thing to let someone do by accident.
    var isUsable: Bool { modifiers != 0 }

    // MARK: NSEvent bridge

    /// From what the recorder caught. Nil when the press carried no modifier.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        guard carbon != 0 else { return nil }
        self.keyCode = UInt32(event.keyCode)
        self.modifiers = carbon
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// The printable name of a virtual key code, as the *active keyboard layout* labels it —
    /// so an AZERTY user reading this sees the letter printed on the key they pressed, not the
    /// US-ANSI letter that happens to share its position. `KeyDisplayName` does the work; a key
    /// the layout cannot answer for falls back to a table and then to its number, which is still
    /// recognisable next to a recorder that just caught it.
    ///
    /// Main thread only, and not from a draw pass: Text Input Services is asked on every call.
    static func keyName(_ code: UInt32) -> String {
        KeyDisplayName.name(
            forKeyCode: code, layoutCharacter: KeyDisplayName.layoutCharacter(forKeyCode: code)
        )
    }
}

/// Registers Worklens's global hotkeys with the window server, so they fire whatever app is
/// frontmost.
///
/// **Why Carbon.** `KeyboardShortcuts` 3.x — the dependency #1 declared for this — uses SwiftUI's
/// `@Entry` macro, and the Command Line Tools toolchain this project is built with ships no
/// `SwiftUIMacros` plugin, so linking it cannot compile. Of the three ways out named in the
/// README (install Xcode, pin a pre-`@Entry` version, or call Carbon directly), this is the
/// third: `RegisterEventHotKey` is 40 lines, has been the mechanism underneath every such
/// library since 10.0, needs no Accessibility permission, and removes a dependency rather than
/// pinning one. The dependency is gone from `Package.swift` with it.
///
/// The C event handler cannot capture context, so the instance is passed as `userData` and the
/// trampoline reads it back — the standard shape for this API.
@MainActor
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    /// Our own id, echoed back in the event so the two hotkeys can be told apart.
    private static let signature = OSType(0x574C_4E53)  // 'WLNS'

    /// Which hotkey. The raw value is the `EventHotKeyID.id` the window server echoes back
    /// (#252): one registry, two slots, so the pause key and the open key cannot evict each
    /// other the way a single `hotKeyRef` made unavoidable.
    enum Slot: UInt32, CaseIterable {
        case pause = 1
        case open = 2
    }

    private var hotKeyRefs: [Slot: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private var actions: [Slot: @MainActor () -> Void] = [:]
    private var registeredSpecs: [Slot: HotkeySpec] = [:]

    private init() {}

    /// What is registered in `slot`, or nil when nothing is.
    func registered(_ slot: Slot) -> HotkeySpec? { registeredSpecs[slot] }

    /// Registers `spec` in `slot`, replacing whatever that slot held before and leaving the
    /// other alone. Returns false when the combination is already taken by another app — the
    /// caller says so rather than pretending.
    @discardableResult
    func register(
        _ spec: HotkeySpec, slot: Slot = .pause, action: @escaping @MainActor () -> Void
    ) -> Bool {
        unregister(slot)
        guard spec.isUsable else { return false }
        actions[slot] = action

        if handlerRef == nil {
            var spec = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)
            )
            let context = Unmanaged.passUnretained(self).toOpaque()
            let status = InstallEventHandler(
                GetApplicationEventTarget(), GlobalHotkey.trampoline, 1, &spec, context, &handlerRef
            )
            guard status == noErr else {
                Log.ui.warn("could not install the hotkey handler (OSStatus \(status))")
                return false
            }
        }

        let id = EventHotKeyID(signature: GlobalHotkey.signature, id: slot.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            spec.keyCode, spec.modifiers, id, GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            // -9878 is `eventHotKeyExistsErr`: another app owns this combination.
            Log.ui.warn("could not register the \(slot) hotkey (OSStatus \(status))")
            actions[slot] = nil
            return false
        }
        hotKeyRefs[slot] = ref
        registeredSpecs[slot] = spec
        Log.ui.info("\(slot) hotkey registered")
        return true
    }

    func unregister(_ slot: Slot) {
        if let ref = hotKeyRefs[slot] { UnregisterEventHotKey(ref) }
        hotKeyRefs[slot] = nil
        registeredSpecs[slot] = nil
        actions[slot] = nil
    }

    func unregister() {
        for slot in Slot.allCases { unregister(slot) }
    }

    fileprivate func fire(_ slot: Slot) {
        actions[slot]?()
    }

    /// The C callback. Hops nothing: hotkey events arrive on the main thread.
    private static let trampoline: EventHandlerUPP = { _, event, userData in
        guard let userData, let event else { return OSStatus(eventNotHandledErr) }
        var id = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &id
        )
        guard status == noErr, id.signature == GlobalHotkey.signature else {
            return OSStatus(eventNotHandledErr)
        }
        guard let slot = GlobalHotkey.Slot(rawValue: id.id) else {
            return OSStatus(eventNotHandledErr)
        }
        let instance = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
        MainActor.assumeIsolated { instance.fire(slot) }
        return noErr
    }
}
