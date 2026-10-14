import SwiftUI
import WorklensCore

/// The reader: your days in the rail shell of the 2026-09 redesign — an icon rail on the left,
/// one page on the right.
///
/// It is not the window #95 deleted. That one was a chat client onto data the MCP server already
/// exposes, and Claude Desktop reads it better; this makes no model call of its own.
///
/// Since the core cut (2026-10-05) it has two places: Today, one day's waterfall, and Weeks, the
/// week's grid. Search, the timeline and the stats are Claude's to read over MCP.
struct ReaderView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            ReaderRail(model: model)
                .zIndex(1)
            // #286: Settings takes the page's place while the gear is lit; the rail stays.
            if let section = model.settingsSection {
                SettingsPage(model: model, section: section)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    // #349: the invented week says so above both pages, with its way out.
                    if model.isShowingSampleWeek { SampleWeekRibbon(model: model) }
                    page
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .id(model.isShowingSampleWeek)
                        .transition(.opacity)
                }
            }
        }
        .background(ReaderTheme.canvas)
        .foregroundStyle(ReaderTheme.text)
        .frame(
            minWidth: Theme.ReaderWindow.minWidth,
            idealWidth: Theme.ReaderWindow.idealWidth,
            minHeight: Theme.ReaderWindow.minHeight,
            idealHeight: Theme.ReaderWindow.idealHeight
        )
        .toolbarBackground(ReaderTheme.canvas, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .background(windowShortcuts)
        .tourOverlay(model.tour)
        .task {
            // The reader tick refreshes the day list and the open document, and nothing else
            // knows this window exists: closing a `Window(id:)` leaves the model's selection
            // where it was, so the model is told when to stop.
            model.readerWindow(isVisible: true)
            await model.refreshReaderIndex()
        }
        .onDisappear { model.readerWindow(isVisible: false) }
    }

    // MARK: The page

    @ViewBuilder
    private var page: some View {
        if !model.readerIndexLoaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !model.readerHasDays {
            // Nothing recorded yet: Today's own plain sentence, and nothing invented to fill it.
            ReaderMessage(symbol: "sun.max", title: ReaderShellCopy.todayNothing, detail: nil)
        } else {
            switch model.readerPlace {
            case .today:
                TodayPage(model: model)
            case .weeks:
                if let document = model.readerDocument, document.kind == .weekly {
                    WeekPage(model: model, document: document)
                } else if model.readerLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ReaderMessage(symbol: "calendar", title: ReaderShellCopy.weekNothing, detail: nil)
                }
            }
        }
    }

    /// Every key this window answers, hung on zero-opacity buttons because an `LSUIElement` app
    /// has no menu bar to hang one on.
    ///
    /// ⌘← and ⌘→ step through the days, or through the weeks on Weeks — the pair every other
    /// "previous / next" in macOS is bound to — and so do ← and → on their own, which is what a
    /// hand reaches for first. Nothing on either page takes the arrows for itself: the waterfall's
    /// bars are reached with Tab, and Settings, which has text fields, turns all four off.
    private var windowShortcuts: some View {
        Group {
            // #286: ⌘, from inside the window too, for when `DockPresence` has not put a menu
            // bar up yet. The top menu's "Settings…" carries the same key.
            Button(String(localized: "Settings…", comment: "Menu row")) { model.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
            Button(ReaderShellCopy.previousDay) { step(by: 1) }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(model.settingsSection != nil)
            Button(ReaderShellCopy.nextDay) { step(by: -1) }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(model.settingsSection != nil)
            Button(ReaderShellCopy.previousDay) { step(by: 1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(model.settingsSection != nil)
            Button(ReaderShellCopy.nextDay) { step(by: -1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(model.settingsSection != nil)
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func step(by offset: Int) {
        if model.readerPlace == .weeks { model.stepWeek(by: offset) } else { model.stepReader(by: offset) }
    }
}

/// A centred sentence: an empty page.
struct ReaderMessage: View {
    let symbol: String
    let title: String
    let detail: String?

    var body: some View {
        VStack(spacing: Theme.Space.row) {
            Image(systemName: symbol)
                .font(ReaderTheme.Size.emptyGlyph)
                .foregroundStyle(ReaderTheme.faint)
            Text(title)
                .font(ReaderTheme.serif(20))
                .foregroundStyle(ReaderTheme.text)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(ReaderTheme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: Theme.ReaderWindow.cardWidth)
            }
        }
        .padding(Theme.Space.pane)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
