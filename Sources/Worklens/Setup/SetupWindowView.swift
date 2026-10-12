import SwiftUI
import WorklensCore

/// The welcome window: the first six pages of a new install (#131, #232, #352, #357).
///
/// Before it, a new install's first act was a notifications dialog nobody had asked for, and
/// capture started by default before anything had said what is recorded. Now Worklens starts
/// nothing of its own accord: the launch gate in `AppModel.startSetupIfNeeded()` holds the
/// scheduler, and it is released when the last page's **Done** is pressed — or by the menu's
/// "Start capturing", which does the same thing from the other side.
///
/// **What #357's second pass changed.** A sixth page, first: light, dark or the system's, as
/// three cards with light ringed. A click applies it and goes on; Return is Continue, which
/// picks the ringed card.
///
/// **What #352 changed.** A fifth page, *See a sample week*, between what Worklens does and
/// Screen Recording: the tour over made-up days. Since #357 it has one button, **Take the tour**,
/// and no Skip: the tour is part of setting up.
///
/// **What #232 changed.** Five pages became four — what Worklens does, Screen Recording, your
/// keys, ready — and none of them is a `Form` any more: a grouped settings form is what you show
/// somebody who already uses the app, not somebody meeting it. The optional grants that were
/// page 4 are one sentence on the last page now, pointing at Settings → Permissions. Page 3
/// asks for the Gemini key alone since the reports, and the Claude key with them, were cut
/// (2026-10-05).
///
/// The window is the same idiom as the reader (#134): a `Window(id:)` scene in `WorklensApp`,
/// fronted through `AppModel.openWindow(id:)`. Nothing here is an `NSWindowController`.
struct SetupWindowView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// The ringed card on the first page. The page sets it from `app_state` when it appears;
    /// it lives here because Continue, down in the footer, picks it.
    @State private var appearancePick: AppearanceChoice = AppearanceChoice.newInstall

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        // Fixed, not resizable: six pages of one column each, sized so page 1 needs no
        // scrolling on a laptop screen. `Theme.SetupWindow` owns both numbers.
        .frame(width: Theme.SetupWindow.minWidth, height: Theme.SetupWindow.idealHeight)
        .task {
            model.setupWindow(isVisible: true)
            // Every page reads a live permission state, and the window can have been open while
            // the user answered a dialog in System Settings.
            model.recheckPermissions()
        }
        .onDisappear { model.setupWindow(isVisible: false) }
    }

    // MARK: Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.row) {
            SetupStepIndicator(page: model.setupPage)
            // #246: one sentence above the heading of a page that was come back to after the
            // relaunch Screen Recording forces — the fact first, and nothing else changed.
            if let resumed = model.setupResumeNote {
                Text(resumed)
                    .font(Theme.Text.rowBody)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(model.setupPage.title)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(model.setupPage.summary)
                .font(Theme.Text.rowBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.pane)
        .padding(.vertical, Theme.Space.section)
        .background(.background)
    }

    @ViewBuilder
    private var page: some View {
        switch model.setupPage {
        case .appearance: SetupAppearancePage(model: model, selection: $appearancePick)
        case .privacy: SetupWelcomePage(model: model)
        case .tour: SetupTourPage()
        case .screenRecording: SetupScreenRecordingPage(model: model)
        case .keys: SetupKeysPage(model: model)
        case .ready: SetupReadyPage(model: model)
        }
    }

    /// One primary button per page, a plain Back, and — where a page can be left with its
    /// question unanswered — one plain button that says so in its own words.
    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.row) {
            // Said on every page, because it is the promise the whole window is here to keep.
            if model.setupPending {
                Text(SetupCopy.nothingCapturedYet)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(SetupCopy.backLabel) { step(to: model.setupPage.previous) }
                    .disabled(model.setupPage.previous == nil)
                Spacer()
                if let skip = model.setupSkipLabel(for: model.setupPage),
                    let next = model.setupPage.next
                {
                    Button(skip) { step(to: next) }
                }
                if model.setupPage == .tour, model.setupTourTaken, let next = model.setupPage.next {
                    // #357: a tour has already ended once, so the page can be passed without
                    // another one. Take the tour stays, as the plain button.
                    Button(SetupCopy.tourTake) { takeTour() }
                    Button(SetupCopy.continueLabel) { step(to: next) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else if model.setupPage == .appearance {
                    // #357 second pass: Return picks the ringed card, the same as clicking it.
                    Button(SetupCopy.continueLabel) { model.chooseSetupAppearance(appearancePick) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else if model.setupPage == .tour {
                    Button(SetupCopy.tourTake) { takeTour() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else if let next = model.setupPage.next {
                    Button(SetupCopy.continueLabel) { step(to: next) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.setupCanContinue(from: model.setupPage))
                } else {
                    Button(SetupCopy.doneLabel) {
                        model.finishSetup()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.horizontal, Theme.Space.pane)
        .padding(.vertical, Theme.Space.section)
        .background(.background)
    }

    /// #352: the tour takes this window's place and brings it back on Screen Recording, so the
    /// window goes away for the length of it.
    private func takeTour() {
        model.recheckPermissions()
        model.takeTourFromWelcome()
        dismiss()
    }

    private func step(to page: SetupPage?) {
        guard let page else { return }
        // Each page shows a live grant, and the answer may have been given in System Settings
        // while this window sat there.
        model.recheckPermissions()
        // #246: `setupMove` writes the page name to `app_state`, so the relaunch macOS forces
        // for Screen Recording comes back here rather than to page one.
        model.setupMove(to: page)
    }
}

/// Where you are, as one dot per page.
///
/// Drawn rather than written: "Step 4 of 6: Screen Recording" is above every page as its own
/// heading already, and a second copy of it in words is chrome. The sentence survives as the
/// accessibility label, so nothing is lost to VoiceOver. The dots scale with the user's text
/// size — #237's rule against hand-set point sizes is about type, and a dot that ignores Larger
/// Text is the same mistake in another shape.
struct SetupStepIndicator: View {
    let page: SetupPage
    @ScaledMetric(relativeTo: .caption) private var dot: CGFloat = 6

    var body: some View {
        HStack(spacing: Theme.Space.row) {
            ForEach(SetupPage.allCases) { each in
                Circle()
                    .fill(each == page ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                    .frame(width: dot, height: dot)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(page.stepLine)
    }
}

/// A heading and its bullets. Page 1's full detail is the last thing still drawn this way.
struct SetupList: View {
    let title: String
    let items: [String]
    @ScaledMetric(relativeTo: .callout) private var bullet: CGFloat = 5

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.row) {
            Text(title)
                .font(Theme.Text.sectionHeader)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(items, id: \.self) { item in
                Label {
                    Text(item).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Circle()
                        .fill(.secondary)
                        .frame(width: bullet, height: bullet)
                        .padding(.top, Theme.Space.row)
                }
                .font(Theme.Text.rowBody)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
