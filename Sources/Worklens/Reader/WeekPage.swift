import SwiftUI
import WorklensCore

/// The Weeks page: the week's calendar (reader redesign).
///
/// Which stretch is which colour is `WeekCalendar`'s decision; this only lays the blocks out.
struct WeekPage: View {
    @ObservedObject var model: AppModel
    let document: ReaderDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 14)
                .padding(.bottom, 18)
            if let calendar = document.calendar, !calendar.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        WeekLegend(week: calendar)
                        WeekGrid(model: model, week: calendar)
                            .tourAnchor(.week)
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 36)
                }
            } else {
                Text(ReaderShellCopy.weekNothing)
                    .foregroundStyle(ReaderTheme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ReaderChevron(
                        systemName: "chevron.left", label: ReaderShellCopy.previousWeek,
                        enabled: model.canStepReader(by: 1)
                    ) { model.stepWeek(by: 1) }
                    Text(document.calendar?.title ?? document.title)
                        .font(ReaderTheme.serif(30))
                        .kerning(-0.45)
                        .foregroundStyle(ReaderTheme.text)
                        .accessibilityAddTraits(.isHeader)
                    ReaderChevron(
                        systemName: "chevron.right", label: ReaderShellCopy.nextWeek,
                        enabled: model.canStepReader(by: -1)
                    ) { model.stepWeek(by: -1) }
                }
                if let line = document.calendar?.line {
                    Text(line)
                        .font(ReaderTheme.Size.control)
                        .monospacedDigit()
                        .foregroundStyle(ReaderTheme.muted)
                }
            }
            Spacer(minLength: 12)
        }
    }
}

/// The week's named apps, Others when a block is drawn as Others, and the meeting swatch, above
/// the grid.
struct WeekLegend: View {
    let week: WeekCalendar.Week

    var body: some View {
        HStack(spacing: 18) {
            ForEach(week.top, id: \.self) { app in
                item(app.name, swatch: RoundedRectangle(cornerRadius: ReaderTheme.Radius.swatch).fill(Color(hex: app.colorHex)))
            }
            if week.days.contains(where: { $0.blocks.contains { $0.category == .others } }) {
                item(
                    ReaderShellCopy.others,
                    swatch: RoundedRectangle(cornerRadius: ReaderTheme.Radius.swatch).fill(ReaderTheme.others)
                )
            }
            item(
                ReaderShellCopy.meeting,
                swatch: RoundedRectangle(cornerRadius: ReaderTheme.Radius.swatch).fill(ReaderTheme.surface)
                    .overlay(RoundedRectangle(cornerRadius: ReaderTheme.Radius.swatch).strokeBorder(ReaderTheme.faint))
            )
        }
        .font(ReaderTheme.Size.rowDetail)
        .foregroundStyle(ReaderTheme.muted)
        .padding(.bottom, 20)
    }

    private func item(_ name: String, swatch: some View) -> some View {
        HStack(spacing: 7) {
            swatch.frame(width: 10, height: 10)
            Text(name)
        }
    }
}

/// Seven columns, 08:00 to 20:00 at forty points an hour. A week that runs earlier or later
/// squeezes its wider window into the same height, so the whole week still fits without scrolling.
struct WeekGrid: View {
    @ObservedObject var model: AppModel
    let week: WeekCalendar.Week

    @State private var hot: String?

    private let hoursWidth: CGFloat = 50
    private let headerHeight: CGFloat = 44
    /// Twelve hours at forty points, whatever the week's window.
    private let gridHeight: CGFloat = 12 * 40
    private var perMinute: CGFloat { gridHeight / CGFloat(week.windowEnd - week.windowStart) }
    /// The even hours inside the window, where the labels and the faint lines sit.
    private var evenHours: [Int] {
        let first = Int(week.windowStart / 60) + 1
        let last = Int(week.windowEnd / 60) - 1
        return first <= last ? (first...last).filter { $0.isMultiple(of: 2) } : []
    }

    var body: some View {
        GeometryReader { geometry in
            let column = (geometry.size.width - hoursWidth) / CGFloat(max(1, week.days.count))
            ZStack(alignment: .topLeading) {
                hours
                ForEach(Array(week.days.enumerated()), id: \.element.id) { index, day in
                    dayHeader(day)
                        .frame(width: column, height: headerHeight, alignment: .topLeading)
                        .offset(x: hoursWidth + CGFloat(index) * column)
                    dayColumn(day, width: column)
                        .frame(width: column, height: gridHeight, alignment: .topLeading)
                        .offset(x: hoursWidth + CGFloat(index) * column, y: headerHeight)
                }
            }
            .overlay(alignment: .topLeading) { tooltip(column: column) }
        }
        .frame(minWidth: hoursWidth + 7 * 84)
        .frame(height: headerHeight + gridHeight + 8)
    }

    private func y(_ minute: Double) -> CGFloat { CGFloat(minute - week.windowStart) * perMinute }

    /// One line of a chip's title, padding included, and a block's label: the heights
    /// `WeekCalendar.placement` keeps clear of each other (#357). A block's label is one line with
    /// thin padding, so a half hour (twenty points, seventeen once the gap under it is taken off)
    /// still carries its app's name (#357 second pass).
    private let chipLabelHeight: CGFloat = 20
    private let blockLabelHeight: CGFloat = 17
    /// The gap under every block, so two blocks one after the other read as two.
    private let blockGap: CGFloat = 3

    /// The least of a block a stretched chip may leave showing: under this it is a sliver, and the
    /// block is not drawn (#357 second pass).
    private let blockVisibleHeight: CGFloat = 10

    private func placement(_ day: WeekCalendar.Day) -> WeekCalendar.Placement {
        WeekCalendar.placement(
            day,
            chipMinutes: Double(chipLabelHeight / perMinute),
            labelMinutes: Double((blockLabelHeight + blockGap) / perMinute),
            minimumBlockVisibleMinutes: Double(blockVisibleHeight / perMinute),
            windowStart: week.windowStart,
            windowEnd: week.windowEnd
        )
    }

    private var hours: some View {
        ZStack(alignment: .topTrailing) {
            ForEach(evenHours, id: \.self) { hour in
                Text(String(format: "%02d:00", hour))
                    .font(ReaderTheme.Size.axis)
                    .monospacedDigit()
                    .foregroundStyle(ReaderTheme.faint)
                    .frame(width: hoursWidth - 10, alignment: .trailing)
                    .offset(y: headerHeight + y(Double(hour) * 60) - 7)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func dayHeader(_ day: WeekCalendar.Day) -> some View {
        let label = VStack(alignment: .leading, spacing: 1) {
            Text(day.label)
                .font(ReaderTheme.Size.control.weight(.semibold))
                .foregroundStyle(day.isToday ? ReaderTheme.accent : ReaderTheme.text)
            Text(day.subtitle)
                .font(ReaderTheme.Size.rowDetail)
                .monospacedDigit()
                .foregroundStyle(ReaderTheme.muted)
        }
        .padding(.horizontal, 6)
        if day.hasData {
            Button { model.openDayFromWeek(day.day) } label: { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help(ReaderShellCopy.openDay(day.label))
                .accessibilityLabel(ReaderShellCopy.openDay(day.label))
        } else {
            label
        }
    }

    private func dayColumn(_ day: WeekCalendar.Day, width: CGFloat) -> some View {
        let placed = placement(day)
        return ZStack(alignment: .topLeading) {
            // Faint lines every two hours, and the column's left edge.
            Rectangle().fill(ReaderTheme.line.opacity(0.7)).frame(width: width, height: 1)
            ForEach(evenHours, id: \.self) { hour in
                Rectangle().fill(ReaderTheme.line.opacity(0.7))
                    .frame(width: width, height: 1)
                    .offset(y: y(Double(hour) * 60))
            }
            Rectangle().fill(ReaderTheme.line).frame(width: 1, height: gridHeight)
            ForEach(day.blocks) { block in
                if let drawn = placed.blocks[block.id] {
                    blockView(block, drawn: drawn, day: day, width: width, labelTop: placed.labels[block.id])
                } else if placed.hidden.contains(block.id) {
                    // Under a meeting's chip and not drawn, but still there for VoiceOver.
                    Color.clear
                        .frame(width: width - 8, height: max(1, CGFloat(block.end - block.start) * perMinute))
                        .offset(x: 4, y: y(block.start))
                        .accessibilityElement()
                        .accessibilityLabel(
                            "\(block.category.name), \(WeekCalendar.range(block.start, block.end))"
                        )
                }
            }
            // Each at least one line tall, so a short meeting's title is never clipped; a block
            // a chip stretches over is drawn from the chip's bottom, so the two never overlap.
            ForEach(day.meetings) { meeting in
                meetingView(meeting, day: day, width: width, drawn: placed.meetings[meeting.id])
            }
            if let now = day.nowMinute, now > week.windowStart, now < week.windowEnd {
                ZStack(alignment: .leading) {
                    Rectangle().fill(ReaderTheme.accent).frame(width: width, height: 2)
                    Circle().fill(ReaderTheme.accent).frame(width: 10, height: 10).offset(x: -5)
                }
                .offset(y: y(now) - 1)
                .accessibilityLabel(String(localized: "Now", comment: "VoiceOver"))
            }
        }
    }

    private func blockView(
        _ block: WeekCalendar.Block, drawn: WeekCalendar.Placement.Span, day: WeekCalendar.Day,
        width: CGFloat, labelTop: Double?
    ) -> some View {
        let height = max(1, CGFloat(drawn.end - drawn.start) * perMinute - blockGap)
        let id = "\(day.day)|b|\(block.id)"
        // Below any meeting chip inside the block; nil is no room clear of every chip.
        let inset = labelTop.map { CGFloat($0 - drawn.start) * perMinute } ?? 0
        let room = labelTop == nil ? 0 : height - inset
        return VStack(alignment: .leading, spacing: 0) {
            if room >= blockLabelHeight {
                Text(block.category.name).fontWeight(.semibold).lineLimit(1)
            }
            if room >= 44 {
                Text(WeekCalendar.range(block.start, block.end)).opacity(0.7).lineLimit(1)
            }
        }
        .font(ReaderTheme.Size.chip)
        .monospacedDigit()
        .foregroundStyle(ReaderTheme.ink)
        .padding(.horizontal, 8)
        .padding(.top, (room >= 22 ? 5 : 1.5) + inset)
        .padding(.bottom, room >= 22 ? 5 : 0)
        .frame(width: width - 8, height: height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: ReaderTheme.Radius.block).fill(Color(hex: week.colorHex(block.category))))
        .brightness(hot == id ? 0.04 : 0)
        .clipped()
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hot = id } else if hot == id { hot = nil }
        }
        .offset(x: 4, y: y(drawn.start) + 1)
        .accessibilityElement()
        .accessibilityLabel("\(block.category.name), \(WeekCalendar.range(block.start, block.end))")
    }

    private func meetingView(
        _ meeting: WeekCalendar.Meeting, day: WeekCalendar.Day, width: CGFloat,
        drawn: WeekCalendar.Placement.Span?
    ) -> some View {
        let top = drawn?.start ?? max(week.windowStart, meeting.start)
        let bottom = drawn?.end ?? min(week.windowEnd, meeting.end)
        let height = max(1, CGFloat(bottom - top) * perMinute - 3)
        let id = "\(day.day)|m|\(meeting.id)"
        return VStack(alignment: .leading, spacing: 0) {
            Text(meeting.title).fontWeight(.semibold).lineLimit(1)
            if height >= 44 {
                Text(WeekCalendar.range(meeting.start, meeting.end))
                    .foregroundStyle(ReaderTheme.muted).lineLimit(1)
            }
        }
        .font(ReaderTheme.Size.chip)
        .monospacedDigit()
        .foregroundStyle(ReaderTheme.text)
        .padding(.horizontal, 8)
        .padding(.vertical, height >= 22 ? 5 : 1)
        .frame(width: width - 8, height: height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: ReaderTheme.Radius.block)
                .fill(hot == id ? ReaderTheme.rail : ReaderTheme.surface)
                .overlay(RoundedRectangle(cornerRadius: ReaderTheme.Radius.block).strokeBorder(ReaderTheme.line))
        )
        .clipped()
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hot = id } else if hot == id { hot = nil }
        }
        .offset(x: 4, y: y(top) + 1)
        .opacity(bottom > top ? 1 : 0)
        .accessibilityElement()
        .accessibilityLabel("\(meeting.title), \(WeekCalendar.range(meeting.start, meeting.end))")
    }

    /// The hovered block's apps, or the hovered meeting's time, beside it.
    @ViewBuilder
    private func tooltip(column: CGFloat) -> some View {
        if let hot, let found = lookup(hot) {
            let flip = found.index >= week.days.count - 2
            let x = hoursWidth + CGFloat(found.index) * column + (flip ? -8 : column + 8)
            Group {
                if let block = found.block {
                    ReaderTooltip(
                        title: block.category.name,
                        value: WeekCalendar.range(block.start, block.end),
                        rows: block.apps.map { ($0.name, Waterfall.duration($0.minutes)) }
                    )
                } else if let meeting = found.meeting {
                    ReaderTooltip(
                        title: meeting.title,
                        value: Waterfall.duration(meeting.minutes),
                        sentences: [
                            "\(ReaderShellCopy.meeting) · \(WeekCalendar.range(meeting.start, meeting.end))",
                        ]
                    )
                }
            }
            .alignmentGuide(.leading) { flip ? $0.width : 0 }
            .offset(x: x, y: headerHeight + max(0, min(found.top, gridHeight - 140)))
        }
    }

    private func lookup(
        _ id: String
    ) -> (index: Int, top: CGFloat, block: WeekCalendar.Block?, meeting: WeekCalendar.Meeting?)? {
        let parts = id.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count == 3, let index = week.days.firstIndex(where: { $0.day == parts[0] })
        else { return nil }
        let day = week.days[index]
        if parts[1] == "b", let block = day.blocks.first(where: { $0.id == parts[2] }) {
            return (index, y(block.start), block, nil)
        }
        if let meeting = day.meetings.first(where: { $0.id == parts[2] }) {
            return (index, y(max(week.windowStart, meeting.start)), nil, meeting)
        }
        return nil
    }
}
