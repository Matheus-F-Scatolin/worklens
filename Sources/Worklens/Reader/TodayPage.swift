import SwiftUI
import WorklensCore

/// The Today page, and nothing else on it: the day, three facts, and the waterfall of where the
/// active time went (reader redesign).
struct TodayPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                header
                if let chart = model.readerDocument?.waterfall {
                    facts(chart)
                    WaterfallChart(chart: chart, dayKey: dayKey)
                        .tourAnchor(.timeline)
                        .padding(.top, 30)
                } else if model.readerLoading {
                    ProgressView().padding(.top, 80)
                } else {
                    Text(ReaderShellCopy.todayNothing)
                        .foregroundStyle(ReaderTheme.muted)
                        .padding(.top, 80)
                }
            }
            .frame(maxWidth: ReaderTheme.columnWidth)
            .padding(.top, 26)
            .padding(.horizontal, 28)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity)
        }
    }

    private var day: String? {
        switch model.readerSelection {
        case let .day(day)?: return day
        default: return model.readerFocusDay
        }
    }

    private var dayKey: String { day ?? "" }

    private var header: some View {
        HStack(spacing: 6) {
            // ⌘← is "previous day", which is one step further down a newest-first list.
            ReaderChevron(
                systemName: "chevron.left", label: ReaderShellCopy.previousDay,
                enabled: model.canStepReader(by: 1)
            ) { model.stepReader(by: 1) }
            Text(day.map { ReaderShellCopy.dayTitle($0, locale: .autoupdatingCurrent) } ?? "")
                .font(ReaderTheme.serif(34))
                .kerning(-0.5)
                .foregroundStyle(ReaderTheme.text)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            ReaderChevron(
                systemName: "chevron.right", label: ReaderShellCopy.nextDay,
                enabled: model.canStepReader(by: -1)
            ) { model.stepReader(by: -1) }
        }
    }

    private func facts(_ chart: Waterfall) -> some View {
        HStack(spacing: 28) {
            ForEach(chart.facts, id: \.label) { fact in
                HStack(spacing: 5) {
                    Text(fact.label).foregroundStyle(ReaderTheme.muted)
                    Text(fact.value)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .foregroundStyle(ReaderTheme.text)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .font(ReaderTheme.Size.control)
    }
}

/// The waterfall, drawn by hand: five (or six) floating bars, dotted connectors between their
/// tops, faint two-hour gridlines, and a tooltip on hover or keyboard focus. Swift Charts could
/// place the bars, but not the dotted connectors or a tooltip that sits beside its bar.
struct WaterfallChart: View {
    let chart: Waterfall
    /// Changes when the day does, which is what replays the rise.
    let dayKey: String

    @State private var hot: Int?
    @State private var risen = false
    /// #357: on the tour's "One bar, opened up" stop the first bar's tooltip is pinned open,
    /// so the stop shows what it says without anybody having to find the bar with the pointer.
    @ObservedObject private var tour = AppModel.shared.tour
    @FocusState private var focused: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let plotHeight: CGFloat = 300
    private let axisWidth: CGFloat = 34

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geometry in
                plot(width: geometry.size.width - axisWidth)
                    .offset(x: axisWidth)
            }
            .frame(height: plotHeight)
            // Above the labels, so a tooltip that reaches below the plot stays on top.
            .zIndex(1)
            labels
                .padding(.leading, axisWidth)
        }
        .task(id: dayKey) { await rise() }
        .onChange(of: focused) { _, value in hot = value }
    }

    private var steps: [Waterfall.Step] { chart.steps }

    /// The bar whose tooltip is open: `momentIndex` while the tour is on its stop, else the one
    /// under the pointer or the keyboard focus.
    private var opened: Int? {
        tour.state?.stop == .moment ? chart.momentIndex : hot
    }
    private var scale: CGFloat { CGFloat(chart.scaleMinutes) }

    private func y(_ minutes: Int) -> CGFloat { plotHeight - CGFloat(minutes) / scale * plotHeight }

    private func plot(width: CGFloat) -> some View {
        let gap = width / CGFloat(steps.count)
        let barWidth = gap * 0.56
        let inset = (gap - barWidth) / 2
        return ZStack(alignment: .topLeading) {
            ForEach(chart.ticks, id: \.self) { tick in
                Rectangle()
                    .fill(tick == 0 ? ReaderTheme.faint.opacity(0.6) : ReaderTheme.line)
                    .frame(width: width, height: 1)
                    .offset(y: y(tick))
                Text(Waterfall.hours(tick))
                    .font(ReaderTheme.Size.chip)
                    .monospacedDigit()
                    .foregroundStyle(ReaderTheme.faint)
                    .frame(width: axisWidth - 10, alignment: .trailing)
                    .offset(x: -axisWidth, y: y(tick) - 7)
                    .accessibilityHidden(true)
            }
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                if index < steps.count - 1 {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 0))
                        path.addLine(to: CGPoint(x: gap - barWidth, y: 0))
                    }
                    .stroke(ReaderTheme.faint, style: StrokeStyle(lineWidth: 1.5, dash: [1.5, 3]))
                    .frame(width: gap - barWidth, height: 1)
                    .offset(x: CGFloat(index) * gap + inset + barWidth, y: y(step.to))
                    .opacity(risen ? 1 : 0)
                    .accessibilityHidden(true)
                }
                bar(step, index: index)
                    .frame(width: barWidth, height: max(1, CGFloat(step.minutes) / scale * plotHeight))
                    .offset(x: CGFloat(index) * gap + inset, y: y(step.to))
            }
        }
        .frame(width: width, height: plotHeight, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            if let hot = opened, steps.indices.contains(hot) {
                let step = steps[hot]
                let flip = hot >= steps.count - 2
                tooltip(step)
                    // #351: the opened bar's tooltip is part of the moment stop, so the cut-out
                    // takes it in too rather than leaving it under the dim.
                    .tourAnchor(hot == chart.momentIndex ? .moment : nil)
                    .alignmentGuide(.leading) { flip ? $0.width : 0 }
                    .offset(
                        x: CGFloat(hot) * gap + inset + (flip ? -12 : barWidth + 12),
                        y: max(0, min(y(step.to), plotHeight - 120))
                    )
            }
        }
    }

    private func bar(_ step: Waterfall.Step, index: Int) -> some View {
        let isHot = opened == index
        return RoundedRectangle(cornerRadius: ReaderTheme.Radius.chip)
            .fill(fill(step))
            .overlay {
                if step.kind == .meetings {
                    RoundedRectangle(cornerRadius: ReaderTheme.Radius.chip).strokeBorder(ReaderTheme.line)
                }
            }
            .brightness(isHot && step.kind != .meetings ? 0.04 : 0)
            .scaleEffect(x: 1, y: risen ? 1 : 0, anchor: .bottom)
            .animation(
                reduceMotion ? nil : .timingCurve(0.2, 0.7, 0.2, 1, duration: 0.5)
                    .delay(Double(index) * 0.09),
                value: risen
            )
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { hot = index } else if hot == index { hot = nil }
            }
            .focusable()
            .focused($focused, equals: index)
            .focusEffectDisabled()
            .overlay {
                if focused == index {
                    RoundedRectangle(cornerRadius: ReaderTheme.Radius.block).stroke(ReaderTheme.accent, lineWidth: 2).padding(-2)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("\(step.name), \(Waterfall.duration(step.minutes))")
            .accessibilityValue(chart.sentence(for: step) ?? "")
            .tourAnchor(index == chart.momentIndex ? .moment : nil)
    }

    private func fill(_ step: Waterfall.Step) -> Color {
        switch step.kind {
        case .app: return Color(hex: step.colorHex ?? AppPalette.hex(forApp: step.name))
        case .others: return ReaderTheme.others
        case .meetings: return ReaderTheme.surface
        case .total: return ReaderTheme.totalBar
        }
    }

    private func tooltip(_ step: Waterfall.Step) -> some View {
        ReaderTooltip(
            title: step.name,
            value: Waterfall.duration(step.minutes),
            detail: chart.summary(for: step),
            rows: chart.rows(for: step),
            sentences: chart.sentence(for: step).map { [$0] } ?? []
        )
    }

    private var labels: some View {
        HStack(spacing: 0) {
            ForEach(steps) { step in
                VStack(spacing: 1) {
                    Text(step.name)
                        .font(ReaderTheme.Size.rowDetail)
                        .foregroundStyle(ReaderTheme.text)
                        .lineLimit(2)
                    Text(Waterfall.duration(step.minutes))
                        .font(ReaderTheme.Size.small)
                        .monospacedDigit()
                        .foregroundStyle(ReaderTheme.muted)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            }
        }
    }

    /// Bars start flat and rise, one after another, whenever the day changes.
    private func rise() async {
        hot = nil
        guard !reduceMotion else {
            risen = true
            return
        }
        risen = false
        try? await Task.sleep(for: .milliseconds(30))
        risen = true
    }
}
