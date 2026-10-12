import AppKit
import SwiftUI
import WorklensCore

// The pieces every Settings page is built from (#286), in the ivory style of the reader: open
// hairline rows on the canvas — a label and a one-line description on the left, the control on
// the right — small muted group labels above them, and terracotta as the only accent. The one
// boxed group is Capture's Access card (`SettingsCard`).

/// A small muted label, an optional sentence under it, and a column of rows with a hairline above
/// the first. `trailing` sits at the label's right edge — a count, a "Copy as CSV".
struct SettingsGroup<Content: View, Trailing: View>: View {
    var label: String?
    var note: String?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(
        _ label: String? = nil,
        note: String? = nil,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.note = note
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if label != nil || !(Trailing.self == EmptyView.self) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    if let label {
                        Text(label)
                            .font(ReaderTheme.Size.groupLabel)
                            .foregroundStyle(ReaderTheme.muted)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Spacer(minLength: 0)
                    trailing
                }
                .padding(.bottom, 6)
            }
            if let note {
                Text(note)
                    .font(ReaderTheme.Size.control)
                    .foregroundStyle(ReaderTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .overlay(alignment: .top) { SettingsHairline() }
        }
    }
}

extension SettingsGroup where Trailing == EmptyView {
    init(_ label: String? = nil, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(label, note: note, trailing: { EmptyView() }, content: content)
    }
}

/// One hairline, in the line colour.
struct SettingsHairline: View {
    var body: some View {
        Rectangle().fill(ReaderTheme.line).frame(height: 1).accessibilityHidden(true)
    }
}

/// Whether a row draws the hairline under itself. Everywhere but inside the Access card, whose
/// border is the last row's edge.
private struct RowLineKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var settingsRowLine: Bool {
        get { self[RowLineKey.self] }
        set { self[RowLineKey.self] = newValue }
    }
}

/// A sentence under a row's description: why it is locked, or what a refused value said.
struct SettingsRowNote: Equatable {
    enum Tone { case muted, attention }
    let text: String
    var tone: Tone = .muted
}

/// One row: the title and its one-line description on the left, the control on the right, and a
/// hairline under it. `leading` is the provider glyph on Connections; `note` is the lock
/// sentence or a refused value's error.
struct SettingsRow<Control: View, Leading: View>: View {
    let title: String
    var detail: String?
    var note: SettingsRowNote?
    var minHeight: CGFloat = 56
    @ViewBuilder var leading: Leading
    @ViewBuilder var control: Control
    @Environment(\.settingsRowLine) private var drawsLine

    init(
        _ title: String,
        detail: String? = nil,
        note: SettingsRowNote? = nil,
        minHeight: CGFloat = 56,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.detail = detail
        self.note = note
        self.minHeight = minHeight
        self.leading = leading()
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            HStack(alignment: .center, spacing: 12) {
                leading
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(ReaderTheme.Size.rowTitle)
                        .foregroundStyle(ReaderTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail)
                            .font(ReaderTheme.Size.rowDetail)
                            .foregroundStyle(ReaderTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let note {
                        Text(note.text)
                            .font(ReaderTheme.Size.rowDetail)
                            .foregroundStyle(note.tone == .attention ? ReaderTheme.warn : ReaderTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            HStack(spacing: 10) { control }
                .fixedSize()
        }
        .padding(.vertical, 12)
        .frame(minHeight: minHeight)
        .overlay(alignment: .bottom) { if drawsLine { SettingsHairline() } }
    }
}

extension SettingsRow where Leading == EmptyView {
    init(
        _ title: String,
        detail: String? = nil,
        note: SettingsRowNote? = nil,
        minHeight: CGFloat = 56,
        @ViewBuilder control: () -> Control
    ) {
        self.init(title, detail: detail, note: note, minHeight: minHeight, leading: { EmptyView() }, control: control)
    }
}

/// The one boxed group: Capture's Access card. Rows inside it lose their own hairline and get a
/// divider between them instead, so the card's border is the last row's edge.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        _VariadicView.Tree(CardLayout()) { content }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: ReaderTheme.Radius.card).fill(ReaderTheme.list))
            .overlay(RoundedRectangle(cornerRadius: ReaderTheme.Radius.card).strokeBorder(ReaderTheme.line))
            .environment(\.settingsRowLine, false)
    }

    private struct CardLayout: _VariadicView_MultiViewRoot {
        func body(children: _VariadicView.Children) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(children.enumerated()), id: \.offset) { index, child in
                    if index > 0 { SettingsHairline() }
                    child
                }
            }
        }
    }
}

// MARK: - Controls

/// The switch: a terracotta track when on, the bar colour when off, a white knob.
struct SettingsSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? ReaderTheme.accent : ReaderTheme.bar)
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                    .padding(2.5)
            }
            .frame(width: 36, height: 21)
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.18), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// A switch with no visible label: the row carries the words.
struct SettingsSwitch: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(label, isOn: $isOn)
            .labelsHidden()
            .toggleStyle(SettingsSwitchStyle())
    }
}

/// The segmented control: a rail-toned track, the selected segment in terracotta.
struct SettingsSegmented<Value: Hashable>: View {
    let label: String
    let options: [(value: Value, title: String)]
    let selection: Value
    let pick: (Value) -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.value == selection
                Button {
                    if !selected { pick(option.value) }
                } label: {
                    Text(option.title)
                        .font(ReaderTheme.Size.control)
                        .foregroundStyle(selected ? Color.white : ReaderTheme.muted)
                        .lineLimit(1)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: ReaderTheme.Radius.segment)
                                .fill(selected ? ReaderTheme.accent : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: ReaderTheme.Radius.railItem).fill(ReaderTheme.rail))
        .overlay(RoundedRectangle(cornerRadius: ReaderTheme.Radius.railItem).strokeBorder(ReaderTheme.line))
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// A menu of choices on the field colour, like the prototype's select. It opens a real menu, with a
/// checkmark on the choice in force; the closed control is drawn here rather than as the system
/// pop-up button, whose arrow box takes the system accent — and terracotta is the only accent.
struct SettingsMenu<Value: Hashable>: View {
    let label: String
    let options: [(value: Value, title: String)]
    let selection: Value
    let pick: (Value) -> Void
    @Environment(\.isEnabled) private var isEnabled

    private var current: String {
        options.first { $0.value == selection }?.title ?? ""
    }

    var body: some View {
        Menu {
            Picker(label, selection: Binding(get: { selection }, set: { if $0 != selection { pick($0) } })) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Text(option.title).tag(option.value)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 8) {
                Text(current)
                    .font(ReaderTheme.Size.control)
                    .foregroundStyle(ReaderTheme.text)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(ReaderTheme.Size.chip)
                    .foregroundStyle(ReaderTheme.muted)
                    .accessibilityHidden(true)
            }
            .padding(.leading, 11)
            .padding(.trailing, 9)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: ReaderTheme.Radius.field).fill(ReaderTheme.field))
            .overlay(RoundedRectangle(cornerRadius: ReaderTheme.Radius.field).strokeBorder(ReaderTheme.line))
            .contentShape(RoundedRectangle(cornerRadius: ReaderTheme.Radius.field))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityLabel(label)
        .accessibilityValue(current)
    }
}

/// The buttons: a quiet bordered one, the terracotta primary, and a destructive one in the warn
/// colour.
struct SettingsButtonStyle: ButtonStyle {
    enum Kind { case plain, primary, danger }
    var kind: Kind = .plain
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ReaderTheme.Size.control)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: ReaderTheme.Radius.field).fill(background(configuration)))
            .overlay(
                RoundedRectangle(cornerRadius: ReaderTheme.Radius.field)
                    .strokeBorder(kind == .primary ? ReaderTheme.accent : ReaderTheme.line)
            )
            .contentShape(RoundedRectangle(cornerRadius: ReaderTheme.Radius.field))
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { hovered = $0 }
    }

    private var foreground: Color {
        switch kind {
        case .plain: return ReaderTheme.text
        case .primary: return .white
        case .danger: return ReaderTheme.warn
        }
    }

    private func background(_ configuration: Configuration) -> Color {
        let pressed = configuration.isPressed || (hovered && isEnabled)
        switch kind {
        case .primary: return pressed ? ReaderTheme.accentInk : ReaderTheme.accent
        case .plain, .danger: return pressed ? ReaderTheme.rail : ReaderTheme.canvas
        }
    }
}

extension ButtonStyle where Self == SettingsButtonStyle {
    static var settings: SettingsButtonStyle { SettingsButtonStyle() }
    static var settingsPrimary: SettingsButtonStyle { SettingsButtonStyle(kind: .primary) }
    static var settingsDanger: SettingsButtonStyle { SettingsButtonStyle(kind: .danger) }
}

/// A text button in the accent's ink: "Show in Finder", "Change", "Review".
struct SettingsLinkStyle: ButtonStyle {
    var muted = false
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ReaderTheme.Size.control)
            .lineLimit(1)
            .foregroundStyle(muted ? ReaderTheme.muted : ReaderTheme.accentInk)
            .underline(hovered && isEnabled)
            .opacity(configuration.isPressed ? 0.7 : (isEnabled ? 1 : 0.5))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}

extension ButtonStyle where Self == SettingsLinkStyle {
    static var settingsLink: SettingsLinkStyle { SettingsLinkStyle() }
    static var settingsMutedLink: SettingsLinkStyle { SettingsLinkStyle(muted: true) }
}

/// A status pill: allowed, not connected, or wanting a yes.
struct SettingsPill: View {
    enum Kind { case ok, off, need }
    let text: String
    var kind: Kind = .ok

    var body: some View {
        Text(text)
            .font(ReaderTheme.Size.small.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, 9)
            .padding(.vertical, 2)
            .background(Capsule().fill(background))
    }

    private var foreground: Color {
        switch kind {
        case .ok: return ReaderTheme.ok
        case .off: return ReaderTheme.muted
        case .need: return ReaderTheme.accentInk
        }
    }

    private var background: Color {
        switch kind {
        case .ok: return ReaderTheme.okSoft
        case .off: return ReaderTheme.rail
        case .need: return ReaderTheme.accentSoft
        }
    }
}

/// A text field on the field colour, with the prototype's corner and border.
struct SettingsFieldStyle: TextFieldStyle {
    var width: CGFloat?
    var alignment: TextAlignment = .leading

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(ReaderTheme.Size.control)
            .multilineTextAlignment(alignment)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(width: width)
            .background(RoundedRectangle(cornerRadius: ReaderTheme.Radius.field).fill(ReaderTheme.field))
            .overlay(RoundedRectangle(cornerRadius: ReaderTheme.Radius.field).strokeBorder(ReaderTheme.line))
    }
}

/// A value shown rather than set: the muted, tabular text beside a read-only row.
struct SettingsValueText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(ReaderTheme.Size.control)
            .foregroundStyle(ReaderTheme.muted)
            .monospacedDigit()
            .lineLimit(1)
            .textSelection(.enabled)
    }
}

/// A "Show ›" / "Hide ›" disclosure button whose chevron turns as it opens.
struct SettingsDisclosureButton: View {
    let title: String
    @Binding var isOpen: Bool
    var accessibilityName: String?

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "chevron.right")
                    .font(ReaderTheme.Size.small)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .animation(.easeOut(duration: 0.15), value: isOpen)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.settingsLink)
        .accessibilityLabel(accessibilityName ?? title)
        .accessibilityValue(isOpen ? String(localized: "Expanded", comment: "VoiceOver") : String(localized: "Collapsed", comment: "VoiceOver"))
    }
}

/// A boxed block of muted text under a disclosure: "What leaves this Mac", the checks' results.
struct SettingsPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) { content }
            .font(ReaderTheme.Size.control)
            .foregroundStyle(ReaderTheme.muted)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: ReaderTheme.Radius.panel).fill(ReaderTheme.list))
            .overlay(RoundedRectangle(cornerRadius: ReaderTheme.Radius.panel).strokeBorder(ReaderTheme.line))
    }
}

/// An inline confirm on the accent wash: the question, Cancel, and the verb.
struct SettingsConfirm: View {
    let question: String
    let verb: String
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(question)
                .font(ReaderTheme.Size.rowTitle)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(String(localized: "Cancel", comment: "Button"), action: cancel)
                .buttonStyle(.settings)
                .keyboardShortcut(.cancelAction)
            Button(verb, action: confirm)
                .buttonStyle(.settingsPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: ReaderTheme.Radius.panel).fill(ReaderTheme.accentSoft))
        .padding(.top, 10)
    }
}

/// A small fixed-width chip naming what kind of thing a row is: App, Site, Window title.
struct SettingsChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(ReaderTheme.Size.chip)
            .foregroundStyle(ReaderTheme.muted)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .frame(minWidth: 52)
            .background(RoundedRectangle(cornerRadius: ReaderTheme.Radius.chip).fill(ReaderTheme.rail))
            .overlay(RoundedRectangle(cornerRadius: ReaderTheme.Radius.chip).strokeBorder(ReaderTheme.line))
    }
}

/// A thin meter: today's spend against the budget, the disk against its limit.
struct SettingsMeter: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(ReaderTheme.line)
                Capsule().fill(ReaderTheme.accent)
                    .frame(width: proxy.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

// MARK: - Lighting up a row a route named

/// Scrolls to and flashes the row a route asked for (`AppModel.settingsHighlight`), once.
struct SettingsAnchorModifier: ViewModifier {
    @ObservedObject var model: AppModel
    let anchor: SettingsAnchor
    var cornerRadius: CGFloat = ReaderTheme.Radius.card
    @State private var lit = false

    func body(content: Content) -> some View {
        content
            .id(anchor)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(ReaderTheme.accent.opacity(lit ? 0.45 : 0), lineWidth: 3)
                    .padding(-3)
                    .allowsHitTesting(false)
            )
            .onAppear { flashIfAsked() }
            .onChange(of: model.settingsHighlight) { _, _ in flashIfAsked() }
    }

    private func flashIfAsked() {
        guard model.settingsHighlight == anchor else { return }
        lit = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            withAnimation(.easeOut(duration: 0.7)) { lit = false }
            if model.settingsHighlight == anchor { model.settingsHighlight = nil }
        }
    }
}

extension View {
    func settingsAnchor(_ anchor: SettingsAnchor, model: AppModel, cornerRadius: CGFloat = ReaderTheme.Radius.card) -> some View {
        modifier(SettingsAnchorModifier(model: model, anchor: anchor, cornerRadius: cornerRadius))
    }
}
