import Carbon.HIToolbox
import Foundation

/// What a physical key is *called* on the keyboard in front of you.
///
/// A hotkey is stored as a virtual key code — a position on the keyboard, not a character — so
/// the combination keeps firing on the same physical key whatever layout is active. Showing it
/// is the opposite problem: the US-ANSI letter of a key code is a lie on an AZERTY or a German
/// keyboard, where the key at `kVK_ANSI_A` is labelled *Q* and the one at `kVK_ANSI_Y` is *Z*.
/// So the character comes from the active keyboard layout, and the table below is only the
/// fallback: non-printing keys, and anything the layout cannot answer for.
///
/// `name(forKeyCode:layoutCharacter:)` is the whole decision and is pure, so it is testable;
/// `layoutCharacter(forKeyCode:)` is the one impure part — it asks Text Input Services.
public enum KeyDisplayName {

    // MARK: The decision

    /// The name to show for `keyCode`, given the character the active layout produces for it
    /// (nil when the layout could not be asked, which is normal for a handwriting or a
    /// transliterating input source).
    ///
    /// A non-printing key always wins: whatever `UCKeyTranslate` says about Space is not what
    /// anybody wants to read in a shortcut.
    public static func name(forKeyCode keyCode: UInt32, layoutCharacter: String?) -> String {
        if let fixed = nonPrinting[Int(keyCode)] { return fixed }
        if let printable = printable(layoutCharacter) { return printable }
        if let ansi = ansiNames[Int(keyCode)] { return ansi }
        return "key \(keyCode)"
    }

    /// A layout character worth showing, uppercased — or nil for empty, whitespace and control
    /// characters, which are what a layout returns when it has nothing useful to say.
    private static func printable(_ character: String?) -> String? {
        guard let character else { return nil }
        guard !character.isEmpty else { return nil }
        for scalar in character.unicodeScalars
        where CharacterSet.controlCharacters.contains(scalar)
            || CharacterSet.whitespacesAndNewlines.contains(scalar)
        {
            return nil
        }
        return character.uppercased()
    }

    // MARK: The layout

    /// The character the active keyboard layout puts on `keyCode`, with no modifiers applied.
    ///
    /// Call this on the main thread — Text Input Services is a main-thread API — and cache what
    /// it returns rather than calling it from a draw pass. `keyboardSelectionDidChange` is when
    /// a cached answer goes stale.
    public static func layoutCharacter(forKeyCode keyCode: UInt32) -> String? {
        guard let data = currentLayoutData(), let bytes = CFDataGetBytePtr(data) else {
            return nil
        }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(
            layout,
            UInt16(truncatingIfNeeded: keyCode),
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadState,
            characters.count,
            &length,
            &characters
        )
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }

    /// The `uchr` data of the current layout. An input method that has none — Japanese, Pinyin,
    /// handwriting — answers nil, and the ASCII-capable layout underneath it is the next best
    /// thing: it is the layout whose physical keys the user is actually looking at.
    private static func currentLayoutData() -> CFData? {
        if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let data = unicodeLayoutData(of: source)
        {
            return data
        }
        if let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() {
            return unicodeLayoutData(of: ascii)
        }
        return nil
    }

    private static func unicodeLayoutData(of source: TISInputSource) -> CFData? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
    }

    // MARK: The tables

    /// Keys with no character of their own. These read the same on every layout.
    public static let nonPrinting: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Escape: "⎋", kVK_Delete: "⌫", kVK_Tab: "⇥",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// The US-ANSI label of a printing key, used only when the layout cannot be asked.
    public static let ansiNames: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Period: ".", kVK_ANSI_Comma: ",", kVK_ANSI_Slash: "/",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Backslash: "\\",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_Grave: "`",
    ]
}
