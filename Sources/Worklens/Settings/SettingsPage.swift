import AppKit
import SwiftUI
import WorklensCore

/// Settings, inside the reader (#286): the section list beside one page, where the reading pages
/// are when the rail's gear is lit. It replaced the separate Settings window, which duplicated
/// controls, leaked key names, and fought the reader for the front (#279).
///
/// Nothing on it has a Save button: every control writes through `AppModel.saveSetting`, which is
/// the `applySetting` path the old panes used, and a toast at the foot says it was saved.
struct SettingsPage: View {
    @ObservedObject var model: AppModel
    let section: SettingsSection

    var body: some View {
        HStack(spacing: 0) {
            SettingsSectionList(model: model, selected: section)
            SettingsContent(model: model, section: section)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .bottom) { SettingsToastView(model: model) }
        .background(SettingsEscape { model.closeSettings() })
    }
}

/// The toast's text, and a counter so the same sentence twice is two toasts.
struct SettingsToast: Equatable {
    let id: Int
    let text: String
}

// MARK: - The section list

/// About 208 pt of text rows on a tone between the rail and the canvas: a serif "Settings", the
/// six sections, a hairline, Advanced in the muted colour, and "Esc to go back" at the foot.
struct SettingsSectionList: View {
    @ObservedObject var model: AppModel
    let selected: SettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "Settings", comment: "Settings heading"))
                .font(ReaderTheme.Size.listTitle)
                .foregroundStyle(ReaderTheme.text)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 16)
                .accessibilityAddTraits(.isHeader)
            ForEach(SettingsSection.primary) { row($0) }
            SettingsHairline()
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            row(.advanced)
            Spacer(minLength: 0)
            Text(String(localized: "Esc to go back", comment: "Settings hint"))
                .font(ReaderTheme.Size.small)
                .foregroundStyle(ReaderTheme.faint)
                .padding(10)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 18)
        .frame(width: ReaderTheme.listWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(ReaderTheme.list)
        .overlay(alignment: .trailing) {
            Rectangle().fill(ReaderTheme.line).frame(width: 1).accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Settings sections", comment: "VoiceOver"))
    }

    private func row(_ section: SettingsSection) -> some View {
        SettingsSectionRow(
            title: section.title,
            isSelected: section == selected,
            isAdvanced: section == .advanced,
            needsYou: model.settingsNeedsYou == section
        ) {
            model.settingsSection = section
        }
    }
}

private struct SettingsSectionRow: View {
    let title: String
    let isSelected: Bool
    let isAdvanced: Bool
    let needsYou: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(isSelected ? ReaderTheme.Size.rowTitle.weight(.medium) : ReaderTheme.Size.rowTitle)
                    .foregroundStyle(isAdvanced && !isSelected ? ReaderTheme.muted : ReaderTheme.text)
                Spacer(minLength: 0)
                if needsYou {
                    Circle().fill(ReaderTheme.accent).frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: ReaderTheme.Radius.field)
                    .fill(isSelected ? ReaderTheme.active : (hovered ? ReaderTheme.active.opacity(0.55) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(needsYou ? String(format: String(localized: "%@, needs you", comment: "VoiceOver"), title) : title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - The page

/// A centred column about 640 pt wide: the configuration banner when there is one, a serif page
/// title, then the section's groups.
private struct SettingsContent: View {
    @ObservedObject var model: AppModel
    let section: SettingsSection

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    // #126: one banner above whichever section is showing. While a configuration
                    // error stands every control below is drawing `Config.defaults()`.
                    ConfigBanner(model: model)
                    header
                    SettingsSectionView(model: model, section: section)
                }
                .frame(maxWidth: ReaderTheme.settingsColumnWidth, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 26)
                .padding(.bottom, 56)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
            // A new section starts at its top, not at the old one's scroll offset.
            .id(section)
            .onAppear {
                scroll(proxy)
                // AppKit hands a fronted window's focus to its first text field, which would put
                // the caret in Usage's budget and take Esc away from going back. A page opens with
                // nothing focused; a click puts the caret where you want it.
                DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
            }
            .onChange(of: model.settingsHighlight) { _, _ in scroll(proxy) }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(section.title)
                    .font(ReaderTheme.Size.pageTitle)
                    .foregroundStyle(ReaderTheme.text)
                    .accessibilityAddTraits(.isHeader)
                if section == .advanced {
                    Text(String(localized: "For tuning and troubleshooting. You rarely need these.", comment: "Settings subtitle"))
                        .font(ReaderTheme.Size.rowTitle)
                        .foregroundStyle(ReaderTheme.muted)
                }
            }
            Spacer(minLength: 0)
            // #153: every page names the page that explains it.
            Button(String(localized: "Learn more\u{2026}", comment: "Button")) { model.openHelp(section.helpDoc) }
                .buttonStyle(.settingsMutedLink)
        }
    }

    /// To the row a route named, once the page has laid it out.
    private func scroll(_ proxy: ScrollViewProxy) {
        guard let anchor = model.settingsHighlight, anchor.section == section else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(anchor, anchor: .center) }
        }
    }
}

/// Which section's page to draw.
struct SettingsSectionView: View {
    @ObservedObject var model: AppModel
    let section: SettingsSection

    var body: some View {
        switch section {
        case .general: GeneralSection(model: model)
        case .capture: CaptureSection(model: model)
        case .privacy: PrivacySection(model: model)
        case .projects: ProjectsSection(model: model)
        case .connections: ConnectionsSection(model: model)
        case .usage: UsageSection(model: model)
        case .advanced: AdvancedSection(model: model)
        }
    }
}

// MARK: - The toast

/// "Saved · Launch at login" at the foot of the page for a moment, then gone.
private struct SettingsToastView: View {
    @ObservedObject var model: AppModel
    @State private var shown: SettingsToast?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let shown {
                Text(shown.text)
                    .font(ReaderTheme.Size.control)
                    .foregroundStyle(ReaderTheme.canvas)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: ReaderTheme.Radius.railItem).fill(ReaderTheme.text))
                    .transition(.opacity.combined(with: .offset(y: 8)))
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .padding(.bottom, 22)
        .padding(.horizontal, 16)
        .allowsHitTesting(false)
        .animation(Theme.Motion.animation(reduceMotion: reduceMotion, .easeOut(duration: 0.18)), value: shown)
        .onChange(of: model.settingsToast) { _, toast in
            guard let toast else { return }
            shown = toast
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [.announcement: toast.text, .priority: NSAccessibilityPriorityLevel.medium.rawValue]
            )
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1800))
                if shown == toast { shown = nil }
            }
        }
    }
}

// MARK: - Esc

/// Esc leaves Settings for the reading place you came from — except while a text field, a
/// shortcut recorder or a menu has the key, where Esc already means something.
///
/// A local key monitor rather than a `.keyboardShortcut(.escape)` button: a key equivalent fires
/// before the focused field sees the key, so it would take Esc away from a half-typed key, and
/// from the recorder that uses it to cancel.
private struct SettingsEscape: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> EscapeView {
        let view = EscapeView()
        view.action = action
        return view
    }

    func updateNSView(_ view: EscapeView, context: Context) { view.action = action }

    final class EscapeView: NSView {
        var action: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
                else { return event }
                // A field being typed in, or a control that wants Esc for itself.
                if window.firstResponder is NSText { return event }
                if let recorder = window.firstResponder as? HotkeyRecorder.RecorderView, recorder.isListening {
                    return event
                }
                if window.attachedSheet != nil { return event }
                self.action?()
                return nil
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
