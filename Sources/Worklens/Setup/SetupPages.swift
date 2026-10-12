import AppKit
import SwiftUI
import WorklensCore

// MARK: - Page 1: what Worklens does

/// The page that exists so nobody finds out what this app does by reading the database (#131),
/// in the three lines #232 cut it to.
///
/// The mark, one sentence each about what is recorded, where it stays and what you get, and the
/// whole of it — the four lists whose every sentence also appears in `PRIVACY.md`, checked by
/// `SetupCopyTests` — one disclosure away for whoever wants it before anything is captured.
/// There is nothing to press: it is the page the user is owed before the one that asks for
/// Screen Recording.
struct SetupWelcomePage: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingDetail = false
    @ScaledMetric(relativeTo: .largeTitle) private var markSize: CGFloat = 72

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                HStack(spacing: Theme.Space.section) {
                    // The app's own icon, at the size the first page of a first launch deserves.
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: markSize, height: markSize)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Theme.Space.row) {
                        ForEach(SetupCopy.Welcome.lines, id: \.self) { line in
                            Text(line)
                                .font(Theme.Text.rowBody)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()

                DisclosureGroup(SetupCopy.Welcome.fullDetail, isExpanded: $showingDetail) {
                    VStack(alignment: .leading, spacing: Theme.Space.section) {
                        SetupList(
                            title: SetupCopy.Privacy.recordsHeading,
                            items: SetupCopy.Privacy.records
                        )
                        SetupList(
                            title: SetupCopy.Privacy.neverRecordsHeading,
                            items: SetupCopy.Privacy.neverRecords
                        )
                        SetupList(
                            title: SetupCopy.Privacy.leavesHeading,
                            items: SetupCopy.Privacy.leaves
                        )
                        SetupList(
                            title: SetupCopy.Privacy.controlsHeading,
                            items: SetupCopy.Privacy.controls
                        )
                    }
                    .padding(.top, Theme.Space.section)
                }
                .font(Theme.Text.rowBody)
                .animation(
                    Theme.Motion.animation(reduceMotion: reduceMotion, Theme.Motion.reveal),
                    value: showingDetail
                )

                HStack(spacing: Theme.Space.section) {
                    Button(SetupCopy.Welcome.privacyLink) { model.openPrivacyDoc() }
                        .buttonStyle(.link)
                    Spacer(minLength: 0)
                }
                Text(SetupCopy.Privacy.footer)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.pane)
        }
    }
}

// MARK: - Page 2: a sample week

/// What you get, before anything is asked of you (#352): a drawing of the sample week, one
/// sentence on what the tour shows and where it hands back to. The one button is the footer's,
/// **Take the tour** (#357): every first run takes it.
struct SetupTourPage: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                VStack(alignment: .leading, spacing: Theme.Space.section) {
                    SampleWeekMiniature()
                        .frame(height: 150)
                    Text(SetupCopy.tourWhy)
                        .font(Theme.Text.rowBody)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
                Text(SetupCopy.tourComesBack)
                    .font(Theme.Text.rowBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.pane)
        }
    }
}

/// The sample week, small and drawn (#357): seven columns, Monday first, each stretch in the
/// colour the Weeks page gives its app and each meeting an outlined chip on top. Plain shapes
/// from `SampleWeek.miniature`, so nothing is shipped as an image and it is the same every time.
struct SampleWeekMiniature: View {
    private let week = SampleWeek.miniature

    /// `M T W T F S S` in this Mac's language, Monday first.
    private var letters: [String] {
        let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols
        guard symbols.count == 7 else { return Array(repeating: "", count: 7) }
        return Array(symbols[1...]) + [symbols[0]]
    }

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 6
            let labelHeight: CGFloat = 16
            let columns = CGFloat(max(1, week.days.count))
            let width = (proxy.size.width - spacing * (columns - 1)) / columns
            let plot = proxy.size.height - labelHeight
            let span = max(1, week.windowEnd - week.windowStart)
            let y: (Double) -> CGFloat = { CGFloat(($0 - week.windowStart) / span) * plot }
            HStack(alignment: .top, spacing: spacing) {
                ForEach(Array(week.days.enumerated()), id: \.offset) { index, blocks in
                    VStack(spacing: 0) {
                        Text(letters[index])
                            .font(ReaderTheme.Size.chip.weight(.semibold))
                            .foregroundStyle(ReaderTheme.muted)
                            .frame(height: labelHeight, alignment: .top)
                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: ReaderTheme.Radius.block)
                                .fill(ReaderTheme.canvas)
                            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                                shape(block)
                                    .frame(
                                        width: width - 6,
                                        height: max(2, y(block.end) - y(block.start) - 1.5)
                                    )
                                    .offset(x: 3, y: y(block.start))
                                    .zIndex(block.isMeeting ? 1 : 0)
                            }
                        }
                        .frame(width: width, height: plot, alignment: .topLeading)
                    }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(SetupCopy.tourPreviewLabel)
    }

    @ViewBuilder
    private func shape(_ block: SampleWeek.Miniature.Block) -> some View {
        let corner = RoundedRectangle(cornerRadius: ReaderTheme.Radius.miniatureBlock, style: .continuous)
        if block.isMeeting {
            corner.fill(ReaderTheme.surface).overlay(corner.strokeBorder(ReaderTheme.faint))
        } else {
            corner.fill(block.colorHex.map { Color(hex: $0) } ?? ReaderTheme.others)
        }
    }
}

// MARK: - Page 3: Screen Recording

/// The one grant capture cannot work without, with the catch that costs people their first ten
/// minutes: the answer reaches the next process, not this one (#117).
struct SetupScreenRecordingPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                VStack(alignment: .leading, spacing: Theme.Space.row) {
                    switch model.screenRecording {
                    case .granted:
                        StatusBadge(level: .good, text: "Granted", subject: "Screen Recording")
                    case .denied:
                        StatusBadge(level: .bad, text: "Not granted", subject: "Screen Recording")
                    case .unknown:
                        StatusBadge(level: .unknown, text: "Unknown", subject: "Screen Recording")
                    }
                    if model.screenRecording == .granted {
                        SettingsNote(text: SetupCopy.screenRecordingGranted, level: .ok)
                    } else {
                        SettingsNote(text: SetupCopy.screenRecordingRelaunch, level: .attention)
                    }
                    HStack {
                        if model.screenRecording != .granted {
                            Button(ScreenRecordingCopy.askLabel) { model.requestScreenRecording() }
                        }
                        Button(String(localized: "Open System Settings", comment: "Button")) {
                            ScreenCaptureService.openScreenRecordingSettings()
                        }
                        if model.canRelaunch {
                            Button(ScreenRecordingCopy.relaunchLabel) { model.relaunch() }
                        }
                        Button(String(localized: "Re-check", comment: "Button")) {
                            model.recheckPermissions()
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, Theme.Space.row)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()

                Text(SetupCopy.screenRecordingWhy)
                    .font(Theme.Text.rowBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.pane)
        }
    }
}

// MARK: - Page 4: your keys

/// The one key Worklens needs (#232).
///
/// Gemini describes your screen, so without it there is nothing to search.
///
/// The fields are `AccountRowView` in its `.setupPage` layout: the same paste, the same Save,
/// the same Verify as Settings → Models & budget, drawn without the form chrome.
struct SetupKeysPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                gemini
                Text(SetupCopy.keysWhy)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.pane)
        }
    }

    private var gemini: some View {
        VStack(alignment: .leading, spacing: Theme.Space.row) {
            SetupCardHeading(title: SetupCopy.geminiHeading, tag: SetupCopy.geminiRequired)
            Text(SetupCopy.geminiWhy)
                .font(Theme.Text.rowBody)
                .fixedSize(horizontal: false, vertical: true)
            if let row = model.accountRows.first(where: { $0.provider == .gemini }) {
                AccountRowView(model: model, row: row, layout: .setupPage)
            }
            SettingsNote(text: SetupCopy.Privacy.billingCaveat, level: .attention)
            Text(SetupCopy.geminiCost)
                .font(Theme.Text.metadata)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link(SetupCopy.geminiLinkLabel, destination: SetupLinks.geminiKey)
                .font(Theme.Text.metadata)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

}

// MARK: - Page 5: ready

/// Where your days show up (#232).
///
/// Two cards. Claude Desktop first, deliberately: it is the way to *ask* about a day, and it is one click through the same `MCPClientConfig` path
/// Settings → Integrations uses — no second installer. Then this app's own window. Underneath,
/// the one line that replaced the old optional-permissions page.
struct SetupReadyPage: View {
    @ObservedObject var model: AppModel
    @StateObject private var claude: ClaudeDesktopModel
    @State private var confirming = false

    init(model: AppModel) {
        self.model = model
        _claude = StateObject(wrappedValue: ClaudeDesktopModel(app: model))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                Text(model.setupReadyLine)
                    .font(Theme.Text.statusTitle)
                    .fixedSize(horizontal: false, vertical: true)
                if model.screenRecording != .granted {
                    SettingsNote(text: SetupCopy.startWithoutScreenRecording, level: .attention)
                }
                claudeCard
                readerCard
                Text(SetupCopy.readyPermissionsFooter)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // #246: the window no longer asks for Notifications — #232's cut took the page
                // that did — so this says when it will, and nothing is asked here.
                Text(NotificationConsent.welcomeLine)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.pane)
        }
        .task { claude.refresh() }
        .confirmationDialog(
            String(localized: "Add Worklens to Claude Desktop's configuration?", comment: "Alert"),
            isPresented: $confirming
        ) {
            Button(String(localized: "Connect", comment: "Button")) {
                Task { await claude.install() }
            }
            Button(String(localized: "Cancel", comment: "Button"), role: .cancel) {}
        }
    }

    private var claudeCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.row) {
            SetupCardHeading(title: SetupCopy.readyClaudeHeading, tag: nil)
            Text(SetupCopy.readyClaudeBody)
                .font(Theme.Text.rowBody)
                .fixedSize(horizontal: false, vertical: true)
            StatusBadge(level: claude.level, text: claude.statusText, subject: "Claude Desktop")
            HStack {
                if claude.claudeInstalled {
                    Button(claude.actionTitle) {
                        if case .pointsHere = claude.health {
                            Task { await claude.check() }
                        } else {
                            confirming = true
                        }
                    }
                    .disabled(claude.busy)
                } else {
                    Link(
                        String(localized: "Get Claude Desktop", comment: "Link"),
                        destination: ClaudeDesktopModel.downloadURL
                    )
                }
                Button(claude.copied ? "Copied" : "Copy JSON") { claude.copyJSON() }
                if claude.busy { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
            }
            if let note = claude.note { SettingsNote(text: note) }
            if let problem = claude.problem { SettingsNote(text: problem, level: .problem) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var readerCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.row) {
            SetupCardHeading(title: SetupCopy.readyReaderHeading, tag: nil)
            Text(SetupCopy.readyReaderBody)
                .font(Theme.Text.rowBody)
                .fixedSize(horizontal: false, vertical: true)
            Button(SetupCopy.readyReaderButton) { model.openReader() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

// MARK: - Shared pieces

/// A card's heading, and the one word that says whether it is required.
struct SetupCardHeading: View {
    let title: String
    let tag: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.row) {
            Text(title)
                .font(Theme.Text.statusTitle)
                .accessibilityAddTraits(.isHeader)
            if let tag {
                Text(tag)
                    .font(Theme.Text.sectionHeader)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The page the key comes from. Opened in the user's own browser: Worklens sends it nothing,
/// and the host has a row in `PRIVACY.md`'s "What leaves your machine" table.
enum SetupLinks {
    static let geminiKey = URL(string: "https://aistudio.google.com/app/apikey")!
}
