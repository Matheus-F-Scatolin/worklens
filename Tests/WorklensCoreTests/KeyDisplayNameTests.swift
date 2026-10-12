import Carbon.HIToolbox
import Foundation
import Testing

@testable import WorklensCore

/// #154: the recorder used to show the US-ANSI letter of a key code, so an AZERTY user was told
/// they had bound a key they had not pressed. These cover the decision alone; asking Text Input
/// Services for the layout character is the untestable half and lives behind
/// `layoutCharacter(forKeyCode:)`.
@Suite("Key display names")
struct KeyDisplayNameTests {

    @Test("the layout character wins over the US-ANSI table")
    func layoutCharacterWins() {
        // AZERTY: the key at kVK_ANSI_A is labelled Q.
        #expect(
            KeyDisplayName.name(forKeyCode: UInt32(kVK_ANSI_A), layoutCharacter: "q") == "Q"
        )
        // German: kVK_ANSI_Y is labelled Z.
        #expect(
            KeyDisplayName.name(forKeyCode: UInt32(kVK_ANSI_Y), layoutCharacter: "z") == "Z"
        )
    }

    @Test("a non-ASCII layout character is shown as it is, uppercased")
    func nonASCIICharacter() {
        #expect(
            KeyDisplayName.name(forKeyCode: UInt32(kVK_ANSI_LeftBracket), layoutCharacter: "ü")
                == "Ü"
        )
    }

    @Test("a non-printing key keeps its symbol whatever the layout says")
    func nonPrintingKeysIgnoreTheLayout() {
        #expect(KeyDisplayName.name(forKeyCode: UInt32(kVK_Space), layoutCharacter: " ") == "Space")
        #expect(KeyDisplayName.name(forKeyCode: UInt32(kVK_Return), layoutCharacter: "\r") == "↩")
        #expect(KeyDisplayName.name(forKeyCode: UInt32(kVK_Escape), layoutCharacter: "x") == "⎋")
        #expect(KeyDisplayName.name(forKeyCode: UInt32(kVK_Delete), layoutCharacter: nil) == "⌫")
        #expect(KeyDisplayName.name(forKeyCode: UInt32(kVK_Tab), layoutCharacter: "\t") == "⇥")
        #expect(KeyDisplayName.name(forKeyCode: UInt32(kVK_F5), layoutCharacter: nil) == "F5")
    }

    @Test("an unusable translation falls back to the table")
    func unusableTranslationFallsBack() {
        for character in ["", " ", "\u{0}", "\u{1B}", "\n"] {
            #expect(
                KeyDisplayName.name(forKeyCode: UInt32(kVK_ANSI_P), layoutCharacter: character)
                    == "P"
            )
        }
    }

    @Test("no layout answer at all falls back to the table")
    func noLayoutAnswer() {
        #expect(KeyDisplayName.name(forKeyCode: UInt32(kVK_ANSI_P), layoutCharacter: nil) == "P")
        #expect(KeyDisplayName.name(forKeyCode: UInt32(kVK_ANSI_7), layoutCharacter: nil) == "7")
        #expect(
            KeyDisplayName.name(forKeyCode: UInt32(kVK_ANSI_Slash), layoutCharacter: nil) == "/"
        )
    }

    @Test("a key nobody has a name for still reads as something")
    func unknownKeyCode() {
        #expect(KeyDisplayName.name(forKeyCode: 200, layoutCharacter: nil) == "key 200")
    }

    @Test("the default pause key resolves to P on a US layout")
    func defaultPauseKey() {
        #expect(KeyDisplayName.name(forKeyCode: UInt32(kVK_ANSI_P), layoutCharacter: "p") == "P")
    }
}
