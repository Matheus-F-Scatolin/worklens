import AppKit
import SwiftUI
import WorklensCore

/// Settings → Usage (#286): what today has cost against the budget, the last 30 days, and the
/// disk.
///
/// From the old window: the Models & budget pane minus the keys (Connections) and the read-only
/// model and price rows (Advanced), and General's data rows. The 30-day table is a bar
/// chart now; "Copy as CSV" copies its columns.
struct UsageSection: View {
    @ObservedObject var model: AppModel
    @State private var budgetText = ""
    @FocusState private var budgetFocused: Bool

    private var spent: Double { model.state.counts.spendUSD }
    private var budget: Double { model.state.budgetUSD }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            hero
            SettingsGroup {
                budgetRow
                if model.menu.spendLevel == .over, let target = model.menu.budgetRaiseTarget {
                    SettingsRow(
                        String(localized: "Summarizing is on hold for today", comment: "Setting"),
                        detail: String(localized: "Screenshots are kept on hold until the budget allows them.", comment: "Setting detail")
                    ) {
                        Button(L10n.format("Raise to %@ and resume", Format.money(target, locale: .autoupdatingCurrent))) {
                            model.raiseBudgetToday(to: target)
                            model.settingsToast(SettingsCopy.saved(String(localized: "Today's budget", comment: "Toast")))
                        }
                        .buttonStyle(.settingsPrimary)
                    }
                }
            }
            SpendChart(model: model)
            storage
        }
        .onAppear { budgetText = Self.amount(model.config.dailyBudgetUSD) }
        .onChange(of: model.config.dailyBudgetUSD) { _, value in
            if !budgetFocused { budgetText = Self.amount(value) }
        }
        .task {
            await model.refreshCounters()
            await model.refreshSpendHistory()
            await model.refreshScreenshotBytes()
        }
    }

    // MARK: Today

    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Format.money(spent, locale: .autoupdatingCurrent))
                .font(ReaderTheme.Size.hero)
                .monospacedDigit()
                .foregroundStyle(ReaderTheme.text)
            Text(UsageSummary.budgetLine(spent: spent, budget: budget))
                .font(ReaderTheme.Size.rowTitle)
                .foregroundStyle(ReaderTheme.muted)
            SettingsMeter(fraction: UsageSummary.fraction(spent: spent, budget: budget))
                .padding(.top, 8)
        }
        .accessibilityElement(children: .combine)
    }

    private var budgetRow: some View {
        SettingsRow(
            String(localized: "Daily budget", comment: "Setting"),
            detail: model.budgetOverrideUSD.map {
                L10n.format("Raised to %@ for today; back to this tomorrow.", Format.money($0, locale: .autoupdatingCurrent))
            } ?? String(localized: "Once it is spent, screenshots wait on hold until tomorrow.", comment: "Setting detail"),
            note: model.settingNote("DAILY_BUDGET_USD")
        ) {
            HStack(spacing: 3) {
                Text(Self.currencySymbol).foregroundStyle(ReaderTheme.muted)
                TextField(String(localized: "Daily budget in dollars", comment: "VoiceOver"), text: $budgetText)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.leading)
                    .monospacedDigit()
                    .frame(width: 64)
                    .focused($budgetFocused)
                    .onSubmit(commitBudget)
            }
            .font(ReaderTheme.Size.control)
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: ReaderTheme.Radius.field).fill(ReaderTheme.field))
            .overlay(
                RoundedRectangle(cornerRadius: ReaderTheme.Radius.field)
                    .strokeBorder(budgetFocused ? ReaderTheme.accent : ReaderTheme.line)
            )
            .disabled(model.isSettingLocked("DAILY_BUDGET_USD"))
            // Committing on blur as well as on Return: a page left with a typed amount would
            // otherwise throw it away.
            .onChange(of: budgetFocused) { _, focused in if !focused { commitBudget() } }
        }
    }

    /// Dollars wherever the user is (docs/copy.md): `$`, or `US$` where the region says so.
    private static var currencySymbol: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = .autoupdatingCurrent
        formatter.currencyCode = "USD"
        return formatter.currencySymbol ?? "$"
    }

    private static func amount(_ usd: Double) -> String {
        Format.decimal(usd, places: 2, locale: .autoupdatingCurrent)
    }

    private func commitBudget() {
        let separator = Locale.autoupdatingCurrent.decimalSeparator ?? "."
        let typed = budgetText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: separator, with: ".")
        guard let value = Double(typed), value >= 0 else {
            budgetText = Self.amount(model.config.dailyBudgetUSD)
            model.settingsFailures["DAILY_BUDGET_USD"] = String(localized: "Enter an amount in dollars, like 2.00.", comment: "Setting error")
            return
        }
        guard abs(value - model.config.dailyBudgetUSD) > 0.000_1 else { return }
        if model.saveSetting("DAILY_BUDGET_USD", String(format: "%.2f", value), as: String(localized: "Daily budget", comment: "Setting")) {
            budgetText = Self.amount(value)
        }
    }

    // MARK: Storage

    private var storage: some View {
        let budgetBytes = Int64(model.config.screenshotDiskBudgetGB * Double(DiskBudget.bytesPerGiB))
        return SettingsGroup(String(localized: "Storage", comment: "Settings group")) {
            SettingsRow(
                String(localized: "Screenshots on disk", comment: "Setting"),
                detail: String(localized: "The oldest are deleted first when the limit is reached.", comment: "Setting detail"),
                note: model.settingNote("SCREENSHOT_DISK_BUDGET_GB")
            ) {
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 6) {
                        SettingsValueText(L10n.format("%@ of", DiskBudget.humanBytes(model.screenshotBytes)))
                        SettingsMenu(
                            label: String(localized: "Disk limit", comment: "Setting"),
                            options: diskChoices.map { ($0, L10n.format("%@ GB", Format.decimal($0, places: $0.rounded() == $0 ? 0 : 1, locale: .autoupdatingCurrent))) },
                            selection: model.config.screenshotDiskBudgetGB
                        ) {
                            model.saveSetting("SCREENSHOT_DISK_BUDGET_GB", String($0), as: String(localized: "Disk limit", comment: "Setting"))
                        }
                        .disabled(model.isSettingLocked("SCREENSHOT_DISK_BUDGET_GB"))
                    }
                    SettingsMeter(fraction: budgetBytes > 0 ? Double(model.screenshotBytes) / Double(budgetBytes) : 0)
                        .frame(width: 180)
                }
            }
            SettingsRow(
                String(localized: "Data folder", comment: "Label"),
                detail: L10n.format(
                    "%@ · %@ in all", model.config.dataDir.lastPathComponent,
                    DiskBudget.humanBytes(model.screenshotBytes + (model.databaseBytes ?? 0))
                )
            ) {
                Button(String(localized: "Show in Finder", comment: "Button")) {
                    model.showInFinder(model.config.dataDir, creating: true)
                }
                .buttonStyle(.settingsLink)
            }
            .help(model.config.dataDir.path)
        }
    }

    private var diskChoices: [Double] {
        let offered: [Double] = [5, 10, 20, 50]
        let current = model.config.screenshotDiskBudgetGB
        return offered.contains(current) ? offered : (offered + [current]).sorted()
    }
}

// MARK: - The chart

/// Thirty bars, today in terracotta, with the summaries split out on hover. Report spend from
/// before the reports were cut (2026-10-05) still shows, for the days it was spent on.
private struct SpendChart: View {
    @ObservedObject var model: AppModel
    @State private var hovered: String?

    private var today: String { DayBoundaries.dayString(Date()) }

    var body: some View {
        let days = UsageSummary.days(model.spendHistory, today: today)
        let ticks = UsageSummary.ticks(for: days)
        SettingsGroup(
            String(localized: "Last 30 days", comment: "Settings group"),
            trailing: {
                Button(String(localized: "Copy as CSV", comment: "Button")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(SpendCSV.render(model.spendHistory), forType: .string)
                    model.settingsToast(String(localized: "Copied 30 days as CSV", comment: "Toast"))
                }
                .buttonStyle(.settingsLink)
                .disabled(model.spendHistory.isEmpty)
            }
        ) {
            chart(days, ticks: ticks)
                .padding(.top, 10)
                .frame(height: 190)
        }
    }

    private func chart(_ days: [UsageSummary.Day], ticks: [Double]) -> some View {
        let top = ticks.last ?? 1
        // Wide enough for `US$ 1,50`, the longest a region writes a tick.
        let axis: CGFloat = 56
        let bottom: CGFloat = 22
        return GeometryReader { proxy in
            let plotHeight = proxy.size.height - bottom
            let plotWidth = proxy.size.width - axis
            let step = plotWidth / CGFloat(max(days.count, 1))
            let barWidth = step * 0.62
            ZStack(alignment: .topLeading) {
                // The gridlines and their dollar labels.
                ForEach(Array(ticks.enumerated()), id: \.offset) { index, tick in
                    let y = plotHeight * (1 - CGFloat(tick / top))
                    Rectangle()
                        .fill(index == 0 ? ReaderTheme.faint : ReaderTheme.line)
                        .frame(width: plotWidth, height: 1)
                        .offset(x: axis, y: y)
                    Text(Format.money(tick, locale: .autoupdatingCurrent))
                        .font(ReaderTheme.Size.chip)
                        .foregroundStyle(ReaderTheme.faint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(width: axis - 8, alignment: .trailing)
                        .offset(y: y - 7)
                }
                ForEach(Array(days.enumerated()), id: \.element.day) { index, day in
                    let height = max(day.totalUSD > 0 ? 2 : 0, plotHeight * CGFloat(day.totalUSD / top))
                    let x = axis + CGFloat(index) * step + (step - barWidth) / 2
                    let isToday = day.day == today
                    RoundedRectangle(cornerRadius: ReaderTheme.Radius.bar)
                        .fill(fill(isToday: isToday, hovered: hovered == day.day))
                        .frame(width: barWidth, height: height)
                        .offset(x: x, y: plotHeight - height)
                    // A full-height hit area, so a zero day still has a hover.
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .frame(width: step, height: plotHeight)
                        .offset(x: axis + CGFloat(index) * step)
                        .onHover { inside in
                            if inside { hovered = day.day } else if hovered == day.day { hovered = nil }
                        }
                        .accessibilityElement()
                        .accessibilityLabel(UsageSummary.label(day: day.day, today: today))
                        .accessibilityValue(Format.money(day.totalUSD, locale: .autoupdatingCurrent))
                    if index % 7 == 1 || isToday {
                        Text(isToday ? String(localized: "Today", comment: "Chart") : shortDay(day.day))
                            .font(ReaderTheme.Size.chip)
                            .foregroundStyle(ReaderTheme.faint)
                            .fixedSize()
                            .frame(width: 60)
                            .offset(x: axis + CGFloat(index) * step + step / 2 - 30, y: plotHeight + 6)
                    }
                }
                if let hovered, let index = days.firstIndex(where: { $0.day == hovered }) {
                    let day = days[index]
                    let x = axis + CGFloat(index) * step + step / 2
                    ReaderTooltip(
                        title: UsageSummary.label(day: day.day, today: today),
                        value: Format.money(day.totalUSD, locale: .autoupdatingCurrent),
                        rows: tooltipRows(day)
                    )
                    .offset(x: min(max(0, x - 90), proxy.size.width - 180), y: -84)
                    .zIndex(2)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Daily spend for the last 30 days", comment: "VoiceOver"))
    }

    private func tooltipRows(_ day: UsageSummary.Day) -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = [
            (String(localized: "Summaries", comment: "Chart"), Format.money(day.summariesUSD, locale: .autoupdatingCurrent)),
        ]
        if day.reportsUSD > 0 {
            rows.append((String(localized: "Reports", comment: "Chart"), Format.money(day.reportsUSD, locale: .autoupdatingCurrent)))
        }
        if day.otherUSD > 0 {
            rows.append((String(localized: "Other", comment: "Chart"), Format.money(day.otherUSD, locale: .autoupdatingCurrent)))
        }
        return rows
    }

    private func fill(isToday: Bool, hovered: Bool) -> Color {
        if isToday { return hovered ? ReaderTheme.accentInk : ReaderTheme.accent }
        return hovered ? ReaderTheme.muted : ReaderTheme.bar
    }

    private func shortDay(_ day: String) -> String {
        guard let date = DayBoundaries.range(day: day)?.start else { return day }
        return Format.shortDate(date, timeZone: .current, locale: .autoupdatingCurrent)
    }
}
