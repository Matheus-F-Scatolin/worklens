import ArgumentParser
import WorklensCore

/// The date argument, parsed by the argument parser rather than by each command.
///
/// Before this, six commands each repeated `DayBoundaries.range(day:) != nil` after reading a
/// `String?`, in three different wordings, and none of them accepted `today` or `yesterday`.
/// Conforming the Core type to `ExpressibleByArgument` moves the check into parsing, so a
/// bad day is a usage error with the same sentence everywhere and a command's `run()` starts
/// with a day it can trust.

extension LocalDay: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(argument)
    }
    // No `defaultValueDescription`: the protocol's default is `"\(self)"`, which for a
    // `LocalDay` is the day itself — `(default: 2026-09-16)` is more use in a help screen than
    // the word "today" would be.
}

/// `--from` and `--to` on `projects assign` (#324): `2026-10-06T15:00` is local time, and an
/// offset or `Z` names an instant. A bad one is a usage error in one sentence.
extension LocalInstant: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(argument)
    }
}
