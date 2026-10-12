import Foundation

/// The company a meeting counts toward, and the rule that named it (#318).
public struct MeetingCompany: Sendable, Equatable {
    /// Why a meeting has the company it has, or why it has none. The raw values are what MCP
    /// prints and what `Slice.meetingRules` is keyed on.
    public enum Rule: String, Sendable, Equatable, CaseIterable {
        /// One company domain on the invite is one you put on a catalog entry.
        case yours
        /// Exactly one company domain on the invite: `company:<domain>`.
        case domain
        /// The title names exactly one catalog entry.
        case title
        /// A Granola note took the answer of the calendar event it was taken on.
        case calendarEvent = "calendar_event"
        /// No answer: the invite has more than one company domain.
        case severalCompanies = "several_companies"
        /// No answer: nobody outside your own domains is on the invite.
        case noCompanyDomain = "no_company_domain"
    }

    /// The catalog key, or `company:<domain>` for a company the catalog has not written yet.
    /// Nil when no rule settled the meeting.
    public var key: String?
    public var name: String?
    public var rule: Rule

    public init(key: String?, name: String?, rule: Rule) {
        self.key = key
        self.name = name
        self.rule = rule
    }
}

/// Puts each Calendar and Granola meeting on a company, computed on read from the attendees'
/// email domains, the title and the catalog (#318). Pure: nothing is stored, and only domains
/// are ever compared, never addresses or names. Bodies and transcripts are never read.
///
/// The rules run in order, and the first that gives exactly one answer wins:
/// 1. `yours`: the invite's company domains are claimed by exactly one entry's `domains`.
/// 2. `domain`: the invite has exactly one company domain, so `company:<domain>`.
/// 3. `title`: the title holds exactly one entry's spelling as whole words (never the house).
/// 4. `calendar_event`: a Granola note still unsettled takes its linked calendar event's answer.
public enum MeetingAttribution {
    /// The key prefix of a company named after its domain.
    public static let companyKeyPrefix = "company:"

    /// Personal mailboxes: a friend's address says nothing about which company a call was with.
    public static let personalMailDomains: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com",
        "yahoo.com", "ymail.com", "icloud.com", "me.com", "mac.com", "aol.com", "proton.me",
        "protonmail.com", "pm.me", "gmx.com", "gmx.net", "mail.com", "zoho.com", "fastmail.com",
        "hey.com", "yandex.com", "qq.com", "163.com",
        "hotmail.com.br", "outlook.com.br", "yahoo.com.br", "uol.com.br",
        "bol.com.br", "terra.com.br", "ig.com.br", "globo.com", "globomail.com",
    ]

    /// The shortest spelling the title rule matches on, so "AI" or "Q3" never names a project.
    public static let minimumTitleSpelling = 3

    /// Every meeting in `events` mapped to its company, by `ContextEvent.id`. Non-meetings are
    /// left out, except that a calendar event a Granola note links to is still read for rule 4.
    public static func resolve(
        _ events: [ContextEvent],
        catalog projects: [ProjectEntry],
        ignoredDomains: [String] = []
    ) -> [String: MeetingCompany] {
        var excluded = Set(ignoredDomains.map(normalized).map(registrableDomain))
        for project in projects where project.kind == .house {
            excluded.formUnion((project.domains ?? []).map(normalized).map(registrableDomain))
        }
        let titled = projects.filter { $0.kind != .house }

        func settle(_ event: ContextEvent) -> MeetingCompany {
            // Only this event's own owner is left out besides the house and ignored domains, so
            // the answer for a meeting never depends on which other meetings were read with it.
            let domains = companyDomains(event, excluded: excluded)
            let claimants = Set(domains.compactMap { domain in
                projects.first {
                    ($0.domains ?? []).map(normalized).map(registrableDomain).contains(domain)
                }?.key
            })
            if claimants.count == 1, let key = claimants.first,
               let entry = projects.first(where: { $0.key == key }) {
                return MeetingCompany(key: entry.key, name: entry.name, rule: .yours)
            }
            if domains.count == 1 {
                let key = companyKeyPrefix + domains[0]
                let name = projects.first { $0.key == key }?.name ?? companyName(domain: domains[0])
                return MeetingCompany(key: key, name: name, rule: .domain)
            }
            if let entry = titleMatch(event.title, in: titled) {
                return MeetingCompany(key: entry.key, name: entry.name, rule: .title)
            }
            return MeetingCompany(
                key: nil, name: nil, rule: domains.isEmpty ? .noCompanyDomain : .severalCompanies
            )
        }

        var answers: [String: MeetingCompany] = [:]
        for event in events where event.isMeeting {
            answers[event.id] = settle(event)
        }
        let calendar = Dictionary(
            events.filter { $0.source == .calendar }.map { ($0.externalId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for event in events where event.isMeeting && event.source == .granola {
            guard answers[event.id]?.key == nil,
                  let linkedId = event.linkedCalendarEventId,
                  let linked = calendar[linkedId]
            else { continue }
            let answer = answers[linked.id] ?? settle(linked)
            guard let key = answer.key else { continue }
            answers[event.id] = MeetingCompany(key: key, name: answer.name, rule: .calendarEvent)
        }
        // A note that names no event takes the answer of the events `ContextBlocks.deduplicate`
        // merges it with (#340): the meetings it overlaps for more than half of the shorter one,
        // that no note names. Every dedupe caller reads meetings only, so a declined invite or an
        // all-day row neither names the note nor blocks it. When the merged meetings name more
        // than one company, the note says so instead of keeping its own reason.
        let meetings = events.filter(\.isMeeting)
        let named = Set(meetings.compactMap { $0.source == .granola ? $0.linkedCalendarEventId : nil })
        for event in meetings where event.source == .granola {
            guard event.linkedCalendarEventId == nil, answers[event.id]?.key == nil else { continue }
            let merged = meetings.filter {
                $0.source == .calendar && !named.contains($0.externalId)
                    && ContextBlocks.overlapsSubstantially(event, $0)
            }
            let keyed = merged.compactMap { answers[$0.id] }.filter { $0.key != nil }
            guard let answer = keyed.first else { continue }
            answers[event.id] = Set(keyed.map(\.key)).count == 1
                ? MeetingCompany(key: answer.key, name: answer.name, rule: .calendarEvent)
                : MeetingCompany(key: nil, name: nil, rule: .severalCompanies)
        }
        return answers
    }

    /// The domains on the invite that can name a company, each collapsed to its registrable
    /// domain: the attendees' domains minus the event owner's, the house entry's, the ignored
    /// ones, personal mailboxes and calendar rooms. Sorted.
    static func companyDomains(_ event: ContextEvent, excluded: Set<String>) -> [String] {
        let own = ownerEmail(event).flatMap(domain(of:)).map(registrableDomain)
        let domains = event.participantEmails.compactMap(domain(of:))
            .filter { !isCalendarResource($0) }
            .map(registrableDomain)
            .filter { domain in
                domain != own && !excluded.contains(domain) && !personalMailDomains.contains(domain)
            }
        return Array(Set(domains)).sorted()
    }

    /// Second-level labels a country code sits under, as in `acme.com.br` or `acme.co.uk`.
    static let countrySecondLevels: Set<String> = ["com", "co", "net", "org", "gov", "edu", "ac"]

    /// `mail.acme.com` → `acme.com`, `rio.acme.com.br` → `acme.com.br`: the last two labels, or
    /// three when the second-to-last is a common second level under a two-letter country code,
    /// so one company's subdomains count as one company.
    static func registrableDomain(_ domain: String) -> String {
        let labels = domain.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return domain }
        let keep = labels[labels.count - 1].count == 2
            && countrySecondLevels.contains(labels[labels.count - 2]) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    /// `c_123@resource.calendar.google.com`, `team@group.calendar.google.com`: rooms and
    /// shared calendars, never a company.
    static func isCalendarResource(_ domain: String) -> Bool {
        domain == "calendar.google.com" || domain.hasSuffix(".calendar.google.com")
    }

    /// Your address on this event: the calendar attendee (or organizer) marked `self`, or the
    /// Granola note's `owner.email`. Read from `raw_json`; nil when the source did not say.
    static func ownerEmail(_ event: ContextEvent) -> String? {
        guard let json = event.rawJSON else { return nil }
        switch event.source {
        case .calendar:
            let attendee = (json["attendees"]?.arrayValue ?? [])
                .first { $0["self"]?.boolValue == true }?["email"]?.stringValue
            let organizer = json["organizer"]?["self"]?.boolValue == true
                ? json["organizer"]?["email"]?.stringValue : nil
            return (attendee ?? organizer).flatMap(ContextEvent.email(in:))
        case .granola:
            return json["owner"]?["email"]?.stringValue.flatMap(ContextEvent.email(in:))
        }
    }

    /// The part after the `@`, lowercased, when it looks like a domain.
    static func domain(of email: String) -> String? {
        guard let at = email.lastIndex(of: "@") else { return nil }
        let domain = normalized(String(email[email.index(after: at)...]))
        return domain.contains(".") ? domain : nil
    }

    static func normalized(_ domain: String) -> String {
        domain.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
            .lowercased()
    }

    /// The domain of a `company:<domain>` key, or nil for any other key.
    public static func companyDomain(ofKey key: String) -> String? {
        guard key.hasPrefix(companyKeyPrefix) else { return nil }
        let domain = normalized(String(key.dropFirst(companyKeyPrefix.count)))
        return domain.isEmpty ? nil : domain
    }

    /// `acme.com` → `Acme`: the domain's first label, capitalised. Edited by `projects rename`.
    public static func companyName(domain: String) -> String {
        let label = domain.split(separator: ".").first.map(String.init) ?? domain
        return label.prefix(1).uppercased() + label.dropFirst()
    }

    /// The one entry whose spelling the title holds as whole words, or nil for none or several.
    static func titleMatch(_ title: String?, in projects: [ProjectEntry]) -> ProjectEntry? {
        guard let title else { return nil }
        let words = self.words(title)
        guard !words.isEmpty else { return nil }
        let hits = projects.filter { project in
            project.spellings.contains { spelling in
                let needle = self.words(spelling)
                return ProjectEntry.fold(spelling).count >= minimumTitleSpelling
                    && !needle.isEmpty && contains(words, run: needle)
            }
        }
        return hits.count == 1 ? hits[0] : nil
    }

    /// Folded and split on anything that is not a letter or a digit.
    static func words(_ text: String) -> [String] {
        ProjectEntry.fold(text)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    static func contains(_ words: [String], run: [String]) -> Bool {
        guard run.count <= words.count else { return false }
        for start in 0...(words.count - run.count) where Array(words[start..<start + run.count]) == run {
            return true
        }
        return false
    }
}

public extension MeetingAttribution {
    /// The same, read from the taxonomy file's projects and ignored domains.
    static func resolve(_ events: [ContextEvent], taxonomy: Taxonomy) -> [String: MeetingCompany] {
        resolve(events, catalog: taxonomy.projectList, ignoredDomains: taxonomy.ignoredDomains ?? [])
    }
}
