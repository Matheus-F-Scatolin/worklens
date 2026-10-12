import SwiftUI
import WorklensCore

/// The band above Today and Weeks while the reader shows the invented sample week (#349):
/// what you are looking at, what happens next (#350), and the way out.
///
/// The sample is never sent anywhere, so the ribbon only has to say it is not yours; the status
/// line under it is the menu's own wording for whatever is stopping your first moments.
struct SampleWeekRibbon: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.section) {
            Image(systemName: "sparkles")
                .foregroundStyle(ReaderTheme.accentInk)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(SampleWeekCopy.ribbon)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(ReaderTheme.text)
                if let status = model.sampleWeekStatusLine {
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(ReaderTheme.muted)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            Spacer(minLength: Theme.Space.section)
            Button(SampleWeekCopy.leave) { model.leaveSampleWeek() }
                .buttonStyle(.settings)
        }
        .padding(.horizontal, Theme.Space.pane)
        .padding(.vertical, Theme.Space.section - 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ReaderTheme.accentSoft)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ReaderTheme.line).frame(height: 1)
        }
    }
}
