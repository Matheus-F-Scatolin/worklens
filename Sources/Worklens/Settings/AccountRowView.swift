import SwiftUI
import WorklensCore

/// #286: one API key's row as the welcome window draws it (`SetupPages`). Settings draws its own
/// in Connections; the welcome window is outside #286, so this view stays for it alone.
///
/// One credential: what it is for, what is set, and the three things you can do about it.
///
/// Two layouts, one sequence. Settings draws it as a `LabeledContent` row inside a grouped
/// `Form`; the welcome window's keys page (#232) draws the same controls under a heading of its
/// own, with no label column and no form chrome. Paste → Save → Verify is untouched between them
/// on purpose: it is one seam, and #232 was asked to restyle it rather than redesign it.
struct AccountRowView: View {
    /// Where this row is being drawn.
    enum Layout {
        /// Settings → Models & budget: a label column, a value column.
        case settingsRow
        /// The welcome window: the card above already names the key and says what it is for, so
        /// the row is the controls alone.
        case setupPage
    }

    @ObservedObject var model: AppModel
    let row: AccountRow
    var layout: Layout = .settingsRow

    @State private var typed = ""
    @State private var editing = false
    @State private var caption: String?
    @State private var captionLevel: StatusLevel = .attention
    @State private var verifying = false
    @State private var verdict: AccountVerification?
    @FocusState private var focused: Bool
    /// The key field keeps a width — a masked key is not text that can wrap — so it is the one
    /// number here, and it grows with the reader's text size (#133).
    @ScaledMetric(relativeTo: .body) private var fieldWidth = Theme.Layout.field

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.row) {
            switch layout {
            case .settingsRow:
                LabeledContent { controls } label: { label }
            case .setupPage:
                controls
            }
            if let note = row.sourceNote {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let caption {
                SettingsNote(text: caption, level: captionLevel)
            }
        }
        // A key typed in one row must not leave the other row claiming yesterday's answer.
        .onChange(of: row.masked) { _, _ in verdict = nil }
    }

    /// What this key is and what it is for. The label column in Settings; the card's own heading
    /// says it on the welcome window, which is why that layout leaves this out.
    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.label)
            Text(row.purpose).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Paste, Save, Verify — the same three in both layouts.
    @ViewBuilder
    private var controls: some View {
        Group {
            if editing {
                HStack(alignment: .firstTextBaseline) {
                    // `SecureField`, never a `TextField` with a reveal toggle: paste works,
                    // the value is never drawn, and the field is cleared the moment it is
                    // submitted.
                    SecureField(String(localized: "Paste your key", comment: "Field"), text: $typed)
                        .labelsHidden()
                        .frame(width: fieldWidth)
                        .focused($focused)
                        .onSubmit(submit)
                        // #246: one field, one step. A whole key arriving in one change is a
                        // paste or a ⌘V, and it saves and asks the provider without a second
                        // button — the two-step that left a saved, unverified, wrong key.
                        .onChange(of: typed) { old, new in
                            guard Accounts.looksPasted(from: old, to: new) else { return }
                            submit()
                        }
                    Button(String(localized: "Save", comment: "Button"), action: submit)
                    Button(String(localized: "Cancel", comment: "Button"), action: cancel)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.masked)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(row.isSet ? .primary : .secondary)
                    // #246: the spinner stands where the field was while the provider is being
                    // asked, so the one action the user took is visibly still running.
                    if verifying { ProgressView().controlSize(.small) }
                    StatusBadge(level: badge, text: statusText, subject: row.label)
                    Spacer(minLength: 0)
                    if row.isEditable {
                        Button(row.isSet ? "Change\u{2026}" : "Set\u{2026}") { beginEditing() }
                    }
                    if row.isStored {
                        Button(String(localized: "Remove", comment: "Button"), action: remove)
                    }
                    // #246: a key pasted here has already been verified as it was pasted. This
                    // button is for a key that came from `.env` or the environment, where there
                    // was no paste to hook onto — and for a key whose answer was not an
                    // acceptance, so a network problem is not a dead end.
                    if row.offersVerify || offersRetry {
                        Button(verifying ? "Verifying\u{2026}" : "Verify") { verify() }
                            .disabled(verifying)
                    }
                }
            }
        }
    }

    // MARK: Status

    private var badge: StatusBadge.Level {
        switch verdict?.status ?? row.status {
        case .ok: return .good
        case .problem: return .bad
        default: return .unknown
        }
    }

    /// Whether to offer the provider a second chance on a key that was pasted here.
    ///
    /// #246 verifies a pasted key once and hides the button afterwards, which is right for an
    /// acceptance and wrong for the other three outcomes: a refusal or a network problem would
    /// otherwise leave re-pasting the key as the only way to ask again.
    private var offersRetry: Bool {
        guard row.isSet, let verdict else { return false }
        return verdict.verdict != .accepted
    }

    private var statusText: String {
        verdict.map { "\(row.statusText): \($0.line)" } ?? row.statusText
    }

    // MARK: Acting

    private func beginEditing() {
        typed = ""
        caption = nil
        editing = true
        focused = true
    }

    private func cancel() {
        typed = ""
        editing = false
        caption = nil
    }

    /// One paste, one step (#246): save, say what the shape looks like, and ask the provider —
    /// in the order `Accounts.entry` puts them in, which is where that sequence is tested.
    private func submit() {
        let entry = Accounts.entry(typed, for: row.provider)
        guard let value = entry.key else {
            // Nothing saveable. The field stays open on what was typed, with the reason.
            show(entry.caption)
            return
        }
        do {
            try model.setCredential(row.provider, value)
            // The typed value goes as soon as it has been written, so nothing holds a key in
            // memory for longer than the save takes.
            typed = ""
            editing = false
            verdict = nil
            show(entry.caption)
            if entry.verifies { verify(keeping: entry.caption) }
        } catch {
            caption = "\(error)"
            captionLevel = .problem
        }
    }

    /// Draws one sentence under the row, or clears the last one.
    private func show(_ note: AccountCaption?) {
        caption = note?.text
        captionLevel = note?.level ?? .attention
    }

    private func remove() {
        do {
            try model.clearCredential(row.provider)
            verdict = nil
            caption = nil
        } catch {
            caption = "\(error)"
            captionLevel = .problem
        }
    }

    /// Asks the provider, keeping `note` under the row while the call is out.
    ///
    /// #246: the shape warning and the provider call are one action, so clearing the caption
    /// here would erase the warning in the same SwiftUI update that wrote it and the user would
    /// never see it. The verdict replaces it when it lands instead.
    private func verify(keeping note: AccountCaption? = nil) {
        verifying = true
        show(note)
        Task {
            let answer = await model.verifyCredential(row.provider)
            verifying = false
            verdict = answer
            guard let answer else { return }
            // #246: the sentence per outcome is `Accounts.verdict`, so the four of them are a
            // tested value rather than four branches of a view.
            show(Accounts.verdict(answer))
        }
    }
}
