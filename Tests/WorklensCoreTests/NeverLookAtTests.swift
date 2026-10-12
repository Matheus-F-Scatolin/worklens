import Foundation
import Testing

@testable import WorklensCore

/// Privacy's mixed "Never look at" list (#286): which of the three blocklists a typed entry goes
/// on, and the delete confirm's sentence.
@Suite("Never look at")
struct NeverLookAtTests {
    private let apps = [
        NeverLookAt.App(name: "1Password", bundleID: "com.1password.1password"),
        NeverLookAt.App(name: "Messages", bundleID: "com.apple.MobileSMS"),
    ]

    @Test("an installed app's name becomes its bundle identifier, in any case")
    func appByName() {
        #expect(NeverLookAt.guess("1password", apps: apps)
            == NeverLookAt.Guess(list: .apps, value: "com.1password.1password", appName: "1Password"))
        #expect(NeverLookAt.guess("  Messages ", apps: apps).value == "com.apple.MobileSMS")
    }

    @Test("a bundle identifier goes on the apps list as typed")
    func bundleIdentifiers() {
        for id in ["com.apple.Safari", "org.mozilla.firefox", "com.tinyspeck.slackmacgap", "com.1password.1password"] {
            #expect(NeverLookAt.guess(id) == NeverLookAt.Guess(list: .apps, value: id), "\(id)")
        }
    }

    @Test("a host or an address goes on the sites list, as its host")
    func sites() {
        #expect(NeverLookAt.guess("bank.com") == NeverLookAt.Guess(list: .sites, value: "bank.com"))
        #expect(NeverLookAt.guess("mail.google.com").list == .sites)
        #expect(NeverLookAt.guess("app.nubank.com.br") == NeverLookAt.Guess(list: .sites, value: "app.nubank.com.br"))
        #expect(NeverLookAt.guess("https://mail.google.com/mail/u/0") == NeverLookAt.Guess(list: .sites, value: "mail.google.com"))
        #expect(NeverLookAt.guess("nubank.com.br:443").value == "nubank.com.br")
        // A path makes even a reverse-DNS shape an address.
        #expect(NeverLookAt.guess("com.example.www/login").list == .sites)
    }

    @Test("a word or a phrase is a window title")
    func titles() {
        #expect(NeverLookAt.guess("Private") == NeverLookAt.Guess(list: .titles, value: "Private"))
        #expect(NeverLookAt.guess("Private Browsing").list == .titles)
        #expect(NeverLookAt.guess("Signal", apps: apps).list == .titles)
        #expect(NeverLookAt.guess("3.5").list == .titles)
        #expect(NeverLookAt.guess("v1.2 notes").list == .titles)
    }

    @Test("an empty field shows App, and every list has a chip")
    func emptyAndChips() {
        #expect(NeverLookAt.guess("   ").list == .apps)
        #expect(NeverLookAt.chip(.apps) == "App")
        #expect(NeverLookAt.chip(.sites) == "Site")
        #expect(NeverLookAt.chip(.titles) == "Window title")
    }

    /// The span is the locale's own (`DateIntervalFormatter`) with its dash made a hyphen, spaced
    /// where Foundation spaced it.
    @Test("the delete confirm names the number and the days")
    func deleteQuestion() {
        let utc = TimeZone(identifier: "UTC")!
        let gb = Locale(identifier: "en_GB")
        let now = Date(timeIntervalSince1970: 1_790_157_600)  // 2026-09-23
        let first = Date(timeIntervalSince1970: 1_788_264_000)  // 2026-09-01 12:00
        let seventh = first.addingTimeInterval(6 * 86_400)
        #expect(NeverLookAt.deleteQuestion(count: 4_312, from: first, to: seventh, now: now, timeZone: utc, locale: gb)
            == "Delete 4,312 screenshots from 1 - 7 Sep?")
        #expect(NeverLookAt.deleteQuestion(count: 1, from: seventh, to: seventh, now: now, timeZone: utc, locale: gb)
            == "Delete 1 screenshot from 7 Sep?")
        let august = first.addingTimeInterval(-2 * 86_400)
        #expect(NeverLookAt.deleteQuestion(count: 12, from: august, to: seventh, now: now, timeZone: utc, locale: gb)
            == "Delete 12 screenshots from 30 Aug - 7 Sep?")
        // The user's grouping, not a hand-written comma.
        let de = Locale(identifier: "de_DE")
        #expect(NeverLookAt.deleteQuestion(count: 4_312, from: first, to: seventh, now: now, timeZone: utc, locale: de)
            .contains("4.312"))
    }
}
