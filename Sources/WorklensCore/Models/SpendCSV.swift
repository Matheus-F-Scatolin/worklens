import Foundation

/// The 30-day spend table as CSV (#133).
///
/// Settings → Models & budget draws that table and offers "Copy as CSV"; this is what lands on
/// the clipboard. It is here rather than in the view for the usual reason — the view has no
/// tests.
///
/// Money is written as a plain four-decimal number with no `$` and no thousands separator: a
/// spreadsheet has to be able to add the column up, and `MenuModel.money`'s display rounding
/// would quietly lose a fraction of a cent per row.
public enum SpendCSV {
    /// The header row, in order: `day`, `describe`, `reports`, `other`, `total`, `calls`, then
    /// `failures`.
    public static let columns = ["day", "describe", "reports", "other", "total", "calls", "failures"]

    /// `columns` and one line per day, newest first — whatever order the caller passes, which is
    /// the order the table shows.
    public static func render(_ days: [DailySpend]) -> String {
        var lines = [row(columns)]
        for day in days {
            lines.append(
                row([
                    day.day,
                    money(day.describeUSD),
                    money(day.reportsUSD),
                    money(day.otherUSD),
                    money(day.costUsd),
                    "\(day.calls)",
                    "\(day.failures)",
                ])
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Four decimals, because a described frame costs a small fraction of a cent and a table
    /// full of `0.00` is a table that says nothing.
    static func money(_ usd: Double) -> String { String(format: "%.4f", usd) }

    static func row(_ fields: [String]) -> String {
        fields.map(escape).joined(separator: ",")
    }

    /// RFC 4180: quote a field that contains a comma, a quote or a newline, and double the
    /// quotes inside it. Nothing Worklens puts in this table needs it today — a day is
    /// `YYYY-MM-DD` — but a CSV writer that assumes its own input is the one that breaks later.
    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
