import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WorklensCore

/// Settings → Privacy (#286): one "Never look at" list, what Worklens keeps, deleting a range, and
/// what leaves this Mac.
///
/// From the old window: the Privacy pane and its three `BlocklistSection`s, folded into one mixed
/// list with a type chip per row. The shortcuts went to General; the key names that used to be
/// the footer are gone.
struct PrivacySection: View {
    @ObservedObject var model: AppModel
    @State private var eraseFrom = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    @State private var eraseTo = Date()
    /// The inline confirm's question and the count it was asked with, while it is up.
    @State private var confirming: (question: String, from: String, to: String)?
    @State private var eraseLine: String?
    @State private var lastErase: String?
    @State private var leavesShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            NeverLookAtList(model: model)
            keeps
            delete
            leaves
        }
        .onAppear { lastErase = formattedLastErase() }
        // An erase ends in a `.done` notice, and that is the moment the last-deleted line changes.
        .onChange(of: model.state.notices.first?.id) { _, _ in lastErase = formattedLastErase() }
    }

    // MARK: What Worklens keeps

    private var keeps: some View {
        SettingsGroup(String(localized: "What Worklens keeps", comment: "Settings group")) {
            ConfigSwitchRow(
                model: model, key: "DELETE_SCREENSHOTS_AFTER_DESCRIBE",
                title: String(localized: "Delete each screenshot once it is summarized", comment: "Setting"),
                detail: String(localized: "Only the one-sentence summary stays on your Mac.", comment: "Setting detail")
            )
            ConfigSwitchRow(
                model: model, key: "DELETE_SENSITIVE_SCREENSHOTS",
                title: String(localized: "Delete sensitive screenshots at once", comment: "Setting"),
                detail: String(localized: "Screenshots the summary flags as showing a password, a card or a private message.", comment: "Setting detail")
            )
            SettingsRow(
                String(localized: "Keep history for", comment: "Setting"),
                detail: model.config.retentionKeepReports
                    ? String(localized: "Timelines stay after the screenshots behind them are deleted.", comment: "Setting detail")
                    : String(localized: "Timelines older than this are deleted too.", comment: "Setting detail"),
                note: model.settingNote("RETENTION_DAYS")
            ) {
                SettingsMenu(
                    label: String(localized: "Keep history for", comment: "Setting"),
                    options: retentionChoices.map { ($0, Self.retentionName($0)) },
                    selection: model.config.retentionDays
                ) {
                    model.saveSetting("RETENTION_DAYS", String($0), as: String(localized: "Keep history for", comment: "Setting"))
                }
                .disabled(model.isSettingLocked("RETENTION_DAYS"))
            }
        }
    }

    private var retentionChoices: [Int] {
        let offered = [30, 90, 365, 0]
        let current = model.config.retentionDays
        return offered.contains(current) ? offered : ([current] + offered.dropLast()).sorted() + [0]
    }

    static func retentionName(_ days: Int) -> String {
        switch days {
        case 0: return String(localized: "Forever", comment: "Setting")
        case 365: return String(localized: "1 year", comment: "Setting")
        default: return L10n.plural(count: days, one: "%lld day", other: "%lld days")
        }
    }

    // MARK: Delete a range

    private var delete: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(String(localized: "Delete", comment: "Settings group")) {
                SettingsRow(
                    String(localized: "Delete a date range", comment: "Setting"),
                    detail: eraseLine
                        ?? lastErase.map { L10n.format("Last deleted: %@", $0) }
                        ?? String(localized: "Screenshots, summaries and timeline for those days.", comment: "Setting detail")
                ) {
                    DatePicker(String(localized: "From", comment: "Date range"), selection: $eraseFrom, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)
                    Text("→").foregroundStyle(ReaderTheme.muted).accessibilityHidden(true)
                    DatePicker(String(localized: "To", comment: "Date range"), selection: $eraseTo, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)
                    Button(String(localized: "Delete…", comment: "Button")) { ask() }
                        .buttonStyle(.settingsDanger)
                }
            }
            if let confirming {
                SettingsConfirm(
                    question: confirming.question,
                    verb: String(localized: "Delete", comment: "Alert button"),
                    cancel: { self.confirming = nil }
                ) {
                    model.eraseDays(from: confirming.from, to: confirming.to, confirmed: true)
                    self.confirming = nil
                    eraseLine = nil
                }
            }
        }
    }

    /// The count the eraser will delete, over the same range, named before anything goes.
    private func ask() {
        let from = min(eraseFrom, eraseTo)
        let to = max(eraseFrom, eraseTo)
        let fromDay = DayBoundaries.dayString(from)
        let toDay = DayBoundaries.dayString(to)
        guard let count = model.eraseCount(from: fromDay, to: toDay) else { return }
        guard count > 0 else {
            confirming = nil
            eraseLine = NeverLookAt.nothingToDelete(from: from, to: to)
            return
        }
        eraseLine = nil
        confirming = (NeverLookAt.deleteQuestion(count: count, from: from, to: to), fromDay, toDay)
    }

    /// `7 Sep 2025 14:05 → 14:15`, in the user's own locale, or nil when nothing was deleted yet.
    private func formattedLastErase() -> String? {
        guard let record = (try? model.eraser?.lastErase()) ?? nil else { return nil }
        let locale = Locale.autoupdatingCurrent
        let timeZone = TimeZone.current
        let from = Format.dateWithYear(record.from, timeZone: timeZone, locale: locale)
            + " " + Format.clock(record.from, timeZone: timeZone, locale: locale)
        return "\(from) → \(Format.clock(record.to, timeZone: timeZone, locale: locale))"
    }

    // MARK: What leaves this Mac (#120)

    private var leaves: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsDisclosureButton(
                title: String(localized: "What leaves this Mac", comment: "Disclosure"),
                isOpen: $leavesShown
            )
            if leavesShown {
                SettingsPanel {
                    bullet(String(localized: "Each screenshot or window text", comment: "Privacy bullet"),
                           String(localized: "goes to Gemini once, for a one-sentence summary.", comment: "Privacy bullet"))
                    bullet(String(localized: "A source you connect", comment: "Privacy bullet"),
                           String(localized: "is read from its own service, and nothing is sent back to it.", comment: "Privacy bullet"))
                    bullet(String(localized: "GitHub", comment: "Privacy bullet"),
                           String(localized: "is asked for the newest version while automatic updates are on.", comment: "Privacy bullet"))
                    bullet(String(localized: "Nothing else.", comment: "Privacy bullet"),
                           String(localized: "No account, no analytics, and every file stays in your data folder.", comment: "Privacy bullet"))
                    Button(String(localized: "Read the privacy note", comment: "Button")) { model.openPrivacyDoc() }
                        .buttonStyle(.settingsLink)
                        .padding(.top, 6)
                }
            }
        }
    }

    private func bullet(_ lead: String, _ rest: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").accessibilityHidden(true)
            (Text(lead).foregroundColor(ReaderTheme.text).fontWeight(.medium) + Text(" " + rest))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - A switch bound to one key

/// A row whose control is one boolean configuration key, saved at once, locked when a layer above
/// the settings file supplies it.
struct ConfigSwitchRow: View {
    @ObservedObject var model: AppModel
    let key: String
    let title: String
    var detail: String?

    var body: some View {
        SettingsRow(title, detail: detail, note: model.settingNote(key)) {
            SettingsSwitch(
                label: title,
                isOn: Binding(
                    get: { model.settingValue(key) == "true" },
                    set: { model.saveSetting(key, String($0), as: title) }
                )
            )
            .disabled(model.isSettingLocked(key))
        }
    }
}

// MARK: - Never look at

/// The three blocklists as one list (#286), each row with a chip saying which it is on, and one
/// field that guesses as you type (`NeverLookAt.guess`). Removing a row you added drops it;
/// removing one `.env` or the built-ins supplied leaves a note that you took it off, which is the
/// only way such an entry can come off without editing that file.
struct NeverLookAtList: View {
    @ObservedObject var model: AppModel
    @State private var draft = ""
    @State private var problem: String?
    /// Every app in the Applications folders, by name, for the guess. Read once, off the main
    /// actor: a LaunchServices walk is not something `body` should do.
    @State private var installed: [NeverLookAt.App] = []
    /// Bundle identifier → the app's own name, for the rows.
    @State private var names: [String: String] = [:]

    private struct Entry: Identifiable {
        let list: Blocklist
        let row: BlocklistRow
        var id: String { "\(list.rawValue):\(row.value)" }
    }

    private var entries: [Entry] {
        [Blocklist.apps, .sites, .titles].flatMap { list in
            list.rows(config: model.config, overlay: model.blocklistOverlay, provenance: model.configProvenance)
                .map { Entry(list: list, row: $0) }
        }
    }

    private var removed: [(list: Blocklist, value: String)] {
        [Blocklist.apps, .sites, .titles].flatMap { list in
            model.blocklistOverlay.removals(from: list).map { (list, $0) }
        }
    }

    private var guess: NeverLookAt.Guess { NeverLookAt.guess(draft, apps: installed) }

    var body: some View {
        let entries = self.entries
        SettingsGroup(
            String(localized: "Never look at", comment: "Settings group"),
            note: String(localized: "Worklens takes no screenshot and reads no text while any of these is in front.", comment: "Settings note"),
            trailing: {
                SettingsValueText(L10n.plural(count: entries.count, one: "%lld entry", other: "%lld entries"))
            }
        ) {
            ForEach(entries) { entry in
                row(entry)
            }
            ForEach(removed, id: \.value) { item in
                removedRow(item.list, item.value)
            }
            adder
            if let problem {
                Text(problem)
                    .font(ReaderTheme.Size.rowDetail)
                    .foregroundStyle(ReaderTheme.warn)
                    .padding(.top, 6)
            }
        }
        .task { await loadApps() }
        .onChange(of: entries.map(\.id)) { _, _ in resolveNames() }
    }

    private func row(_ entry: Entry) -> some View {
        let name = entry.list == .apps ? (names[entry.row.value] ?? entry.row.value) : entry.row.value
        return HStack(spacing: 12) {
            SettingsChip(text: NeverLookAt.chip(entry.list))
            Text(name)
                .font(ReaderTheme.Size.rowTitle)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(entry.list == .apps ? entry.row.value : "")
            Spacer(minLength: 0)
            Button {
                act {
                    try model.unblock(entry.row.value, in: entry.list)
                    model.settingsToast(L10n.format("Removed %@. Worklens looks at it again.", name))
                }
            } label: {
                Image(systemName: "xmark")
                    .font(ReaderTheme.Size.small)
                    .foregroundStyle(ReaderTheme.faint)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.format("Remove %@", name))
            .help(String(localized: "Look at it again", comment: "Tooltip"))
        }
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) { SettingsHairline() }
    }

    /// An entry you took off a list something else supplies, kept so nothing looks lost.
    private func removedRow(_ list: Blocklist, _ value: String) -> some View {
        HStack(spacing: 12) {
            SettingsChip(text: NeverLookAt.chip(list))
            Text(list == .apps ? (names[value] ?? value) : value)
                .font(ReaderTheme.Size.rowTitle)
                .strikethrough()
                .foregroundStyle(ReaderTheme.muted)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(String(localized: "Restore", comment: "Button")) {
                act {
                    try model.restoreBlock(value, in: list)
                    model.settingsToast(SettingsCopy.saved(String(localized: "Never look at", comment: "Settings group")))
                }
            }
            .buttonStyle(.settingsMutedLink)
        }
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) { SettingsHairline() }
    }

    private var adder: some View {
        HStack(spacing: 10) {
            SettingsChip(text: NeverLookAt.chip(guess.list))
                .opacity(0.9)
            TextField(String(localized: "Add an app, a site or a window title", comment: "Placeholder"), text: $draft)
                .textFieldStyle(.plain)
                .font(ReaderTheme.Size.control)
                .onSubmit(add)
            Button(String(localized: "Add", comment: "Button"), action: add)
                .buttonStyle(.settings)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            Button(String(localized: "Choose an app…", comment: "Button"), action: chooseApp)
                .buttonStyle(.settings)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { SettingsHairline() }
    }

    private func add() {
        let guess = self.guess
        guard !guess.value.isEmpty else { return }
        act {
            try model.block(guess.value, in: guess.list)
            draft = ""
            model.settingsToast(SettingsCopy.saved(String(localized: "Never look at", comment: "Settings group")))
        }
    }

    /// `/Applications`, one app, and its identifier read straight out of the bundle.
    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "Pick an app Worklens should never look at.", comment: "Open panel")
        panel.prompt = String(localized: "Never look at", comment: "Open panel")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let identifier = Bundle(url: url)?.bundleIdentifier else {
            problem = L10n.format("%@ has no bundle identifier, so Worklens has nothing to match on.", url.lastPathComponent)
            return
        }
        let name = FileManager.default.displayName(atPath: url.path)
        act {
            try model.block(identifier, in: .apps)
            model.settingsToast(L10n.format("Chose %@ · Saved", name))
        }
    }

    /// Every edit reports its own failure where it happened: a list that silently refuses an
    /// entry is worse than no list. Only the list is logged, never the entry (`AppModel.block`).
    private func act(_ change: () throws -> Void) {
        do {
            try change()
            problem = nil
        } catch let error as BlocklistError {
            problem = error.description
        } catch {
            problem = "\(error)"
        }
        resolveNames()
    }

    private func resolveNames() {
        var found: [String: String] = [:]
        for entry in entries where entry.list == .apps {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.row.value) {
                found[entry.row.value] = FileManager.default.displayName(atPath: url.path)
            }
        }
        for (list, value) in removed where list == .apps {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: value) {
                found[value] = FileManager.default.displayName(atPath: url.path)
            }
        }
        names = found
    }

    private func loadApps() async {
        resolveNames()
        installed = await Task.detached(priority: .utility) { NeverLookAtList.scanApplications() }.value
    }

    /// The `.app` bundles in the three Applications folders and Utilities, one level deep.
    nonisolated static func scanApplications() -> [NeverLookAt.App] {
        let manager = FileManager.default
        let folders = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        var apps: [NeverLookAt.App] = []
        for folder in folders {
            let items = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for url in items where url.pathExtension == "app" {
                guard let id = Bundle(url: url)?.bundleIdentifier else { continue }
                apps.append(NeverLookAt.App(name: url.deletingPathExtension().lastPathComponent, bundleID: id))
            }
        }
        return apps
    }
}
