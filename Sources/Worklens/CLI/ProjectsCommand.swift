import ArgumentParser
import Foundation
import WorklensCore

/// `worklens projects …` — the canonical project list the timeline headings, the by-project table
/// and the describe prompt all read (#90).
///
/// The list lives in `taxonomy.json` under `projects`, grows on its own (`learn`) and is corrected
/// by hand here. Every write goes through `TaxonomyStore.save`, so a bad edit is refused rather
/// than written.
struct ProjectsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "projects",
        abstract: "List and correct the canonical project list.",
        subcommands: [
            ListCommand.self, LearnCommand.self, RenameCommand.self,
            MergeCommand.self, AliasCommand.self, ForgetCommand.self,
            KindCommand.self, CheckCommand.self, CoverageCommand.self,
            RuleCommand.self, AssignCommand.self,
        ],
        defaultSubcommand: ListCommand.self
    )

    /// Everything but `list` needs the database as well as the taxonomy file.
    static func catalog() throws -> (catalog: ProjectCatalog, store: TaxonomyStore) {
        let config = try CLIConfig.load()
        let store = try TaxonomyStore(dataDir: config.dataDir)
        let db = try Database(dataDir: config.dataDir)
        return (ProjectCatalog(db: db, taxonomy: store), store)
    }

    static func printList(_ projects: [ProjectEntry]) {
        guard !projects.isEmpty else {
            print("(no projects yet: run `worklens projects learn` after a described day)")
            return
        }
        for project in projects {
            let aliases = project.aliases ?? []
            let kind = project.kind.map { "  [\($0.rawValue)]" } ?? ""
            let trailer = aliases.isEmpty ? "" : "  aliases: \(aliases.joined(separator: ", "))"
            let domains = (project.domains ?? []).isEmpty
                ? "" : "  domains: \((project.domains ?? []).joined(separator: ", "))"
            print("\(project.key)  \(project.name)\(kind)\(trailer)\(domains)")
        }
    }

    struct ListCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list", abstract: "Show every project with its aliases."
        )

        @OptionGroup var output: JSONOutputOptions

        /// `{file, version, projects: [{key, name, kind, aliases, domains}], ignored_domains}` — the
        /// header the text form prints plus the list it prints under it. `kind` is null on an
        /// unmarked project; `domains` (#318) are the meeting domains that count toward it.
        private struct Payload: Encodable {
            struct Project: Encodable {
                let key: String
                let name: String
                let kind: String?
                let aliases: [String]
                let domains: [String]

                func encode(to encoder: any Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(key, forKey: .key)
                    try container.encode(name, forKey: .name)
                    try container.encode(kind, forKey: .kind)
                    try container.encode(aliases, forKey: .aliases)
                    try container.encode(domains, forKey: .domains)
                }

                enum CodingKeys: String, CodingKey { case key, name, kind, aliases, domains }
            }
            let file: String
            let version: Int
            let projects: [Project]
            let ignoredDomains: [String]

            enum CodingKeys: String, CodingKey {
                case file, version, projects
                case ignoredDomains = "ignored_domains"
            }
        }

        func run() throws {
            let config = try CLIConfig.load()
            let store = try TaxonomyStore(dataDir: config.dataDir)
            if output.json {
                let payload = Payload(
                    file: store.fileURL.path,
                    version: store.current.version,
                    projects: store.projects.map {
                        Payload.Project(
                            key: $0.key, name: $0.name, kind: $0.kind?.rawValue, aliases: $0.aliases ?? [],
                            domains: $0.domains ?? []
                        )
                    },
                    ignoredDomains: store.current.ignoredDomains ?? []
                )
                print(try CLIOutput.jsonString(payload))
                return
            }
            print("file      \(store.fileURL.path)")
            print("version   \(store.current.version)")
            print("projects  \(store.projects.count)")
            print("")
            ProjectsCommand.printList(store.projects)
            if let ignored = store.current.ignoredDomains, !ignored.isEmpty {
                print("")
                print("ignored domains  \(ignored.joined(separator: ", "))")
            }
        }
    }

    struct LearnCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "learn",
            abstract: "Fold recent days' project hints into the list (aliases, and new projects "
                + "seen on two or more days), and a company:<domain> entry for each company "
                + "domain that alone named a meeting."
        )

        @Option(help: ArgumentHelp("Last day of the window. " + LocalDay.argumentHelp))
        var date: LocalDay?

        @Option(help: "How many days back to read.")
        var days = ProjectCatalog.learningWindow

        @Flag(help: "Show what would change without writing taxonomy.json.")
        var dryRun = false

        func run() throws {
            let (catalog, store) = try ProjectsCommand.catalog()
            let day = (date ?? .today()).string
            let before = store.projects

            let change: ProjectCatalog.Change
            if dryRun {
                // Same window, same rules, without the save: `learn` is the only writer.
                change = try catalog.preview(upTo: day, days: days)
            } else {
                change = try catalog.learn(upTo: day, days: days)
            }

            print("window    \(days) days ending \(day) (\(change.daysRead) with hints)")
            // #318: a meeting domain whose name a project already answers to is not added twice.
            for merge in change.suggestedMerges {
                print("suggest   worklens projects merge \(merge.key) \(merge.into)")
            }
            guard !change.isEmpty else {
                print("status    nothing to add (\(before.count) projects)")
                return
            }
            for project in change.addedProjects {
                print("new       \(project.key)  \(project.name)"
                    + ((project.aliases ?? []).isEmpty
                        ? "" : "  aliases: \((project.aliases ?? []).joined(separator: ", "))"))
            }
            for (key, aliases) in change.addedAliases.sorted(by: { $0.key < $1.key }) {
                print("alias     \(key) += \(aliases.joined(separator: ", "))")
            }
            print("status    \(dryRun ? "dry run, nothing written" : "saved, version \(store.current.version)")")
        }
    }

    struct RenameCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rename",
            abstract: "Rename a project. The old name is kept as an alias."
        )

        @Argument(help: "The project's key.") var key: String
        @Argument(help: "The name to show from now on.") var name: String

        func run() throws {
            let (catalog, store) = try ProjectsCommand.catalog()
            try catalog.rename(key: key, to: name)
            ProjectsCommand.printList(store.projects)
        }
    }

    struct MergeCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "merge",
            abstract: "Fold one project into another, keeping its spellings as aliases."
        )

        @Argument(help: "The project to fold away.") var key: String
        @Argument(help: "The project it becomes.") var into: String

        func run() throws {
            let (catalog, store) = try ProjectsCommand.catalog()
            try catalog.merge(key: key, into: into)
            ProjectsCommand.printList(store.projects)
        }
    }

    struct AliasCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "alias", abstract: "Add or remove a spelling a project answers to."
        )

        @Argument(help: "The project's key.") var key: String
        @Argument(help: "The spelling.") var alias: String
        @Flag(help: "Remove the spelling instead of adding it.") var remove = false

        func run() throws {
            let (catalog, store) = try ProjectsCommand.catalog()
            if remove {
                try catalog.removeAlias(alias, from: key)
            } else {
                try catalog.addAlias(alias, to: key)
            }
            ProjectsCommand.printList(store.projects)
        }
    }

    struct ForgetCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "forget",
            abstract: "Remove a project the learner should not have created."
        )

        @Argument(help: "The project's key.") var key: String

        func run() throws {
            let (catalog, store) = try ProjectsCommand.catalog()
            try catalog.forget(key: key)
            ProjectsCommand.printList(store.projects)
        }
    }

    struct KindCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "kind",
            abstract: "Mark a project as your firm (house), a company, a side project, or none.",
            discussion: """
                The describer is told each project's kind (#315). Use `house` for the firm you \
                work at: it gets the firm's own inbox, calendar and admin work, and nothing else. \
                Only one project can be the house.
                """
        )

        @Argument(help: "The project's key.") var key: String
        @Argument(help: "house, company, side, or none.") var kind: String

        func run() throws {
            let value = kind.lowercased()
            let parsed = ProjectKind(rawValue: value)
            guard parsed != nil || value == "none" else {
                throw ValidationError("kind must be house, company, side or none")
            }
            let (catalog, store) = try ProjectsCommand.catalog()
            try catalog.setKind(parsed, for: key)
            ProjectsCommand.printList(store.projects)
        }
    }

    struct CheckCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "check",
            abstract: "Re-ask recent house screenshots which project they are about, and count the answers.",
            discussion: """
                Sends up to --sample recent screenshots the describer gave to your house project \
                back through the current prompt, text only, and prints where they would go now. \
                Nothing about those screenshots is changed: the only rows written are the cost \
                rows in llm_calls, and the daily budget applies. --dry-run sends nothing.
                """
        )

        @Option(help: "How many screenshots to ask about.")
        var sample: Int = ProjectKeyCheck.defaultSample

        @Flag(help: "Count the screenshots that would be asked about, and send nothing.")
        var dryRun = false

        @OptionGroup var output: JSONOutputOptions

        func run() async throws {
            guard sample > 0 else { throw ValidationError("--sample must be at least 1") }
            let stack = try DescribeStack(requireKey: !dryRun)
            let projects = stack.taxonomy.projects
            guard projects.contains(where: { $0.kind == .house }) else {
                throw CLIFailure.config(
                    "No project is marked as your house yet: run `worklens projects kind <key> house` first."
                )
            }
            let picked = try ProjectKeyCheck.toAsk(db: stack.db, projects: projects, sample: sample)
            if dryRun {
                if output.json {
                    print(try CLIOutput.jsonString(["would_ask": picked.count]))
                } else {
                    print("would ask  \(picked.count) screenshots (dry run: nothing sent)")
                }
                return
            }

            var outcomes: [DescribeWorker.ProbeOutcome] = []
            var stoppedByBudget = false
            for captureID in picked {
                let outcome = try await stack.worker.probe(captureId: captureID)
                if outcome == .overBudget {
                    stoppedByBudget = true
                    break
                }
                outcomes.append(outcome)
            }
            let tally = ProjectKeyCheck.tally(outcomes, projects: projects)
            if output.json {
                print(try CLIOutput.jsonString(tally))
                return
            }
            print("asked         \(tally.sampled)")
            print("stayed house  \(tally.stayedHouse)")
            print("company       \(tally.company)")
            print("side          \(tally.side)")
            print("unmarked      \(tally.unmarked)")
            print("none          \(tally.none)")
            print("failed        \(tally.failed)")
            print("cost          \(Format.money(tally.costUSD))")
            if stoppedByBudget {
                print("stopped early: today's budget is spent")
            }
        }
    }
}

extension ProjectsCommand {
    /// `worklens projects coverage` (#322): how much of your screen and meeting time the project
    /// spans attribute, and why the rest is not, next to what each frame alone would say. Minutes
    /// and counts only: never a project key, name, title or URL.
    struct CoverageCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "coverage",
            abstract: "Show how much of your time has a project, and why the rest has none."
        )

        static let defaultDays = 14

        @Option(help: "First day. Defaults to 14 complete days back.")
        var from: LocalDay?

        @Option(help: "Last day, inclusive. Defaults to yesterday.")
        var to: LocalDay?

        @OptionGroup var output: JSONOutputOptions

        typealias Payload = ProjectSpanService.CoverageReport
        typealias Rule = ProjectSpanService.CoverageMinutes

        func run() throws {
            let config = try CLIConfig.load()
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            func day(_ offset: Int) -> String {
                DayBoundaries.dayString(calendar.date(byAdding: .day, value: offset, to: today) ?? today)
            }
            let toDay = to?.string ?? day(-1)
            let fromDay = from?.string ?? day(-Self.defaultDays)
            guard fromDay <= toDay else { throw ValidationError("--from must not be after --to") }

            let taxonomy = try? TaxonomyStore(dataDir: config.dataDir)
            let service = ProjectSpanService(
                try Database(dataDir: config.dataDir),
                projects: { taxonomy?.projects ?? [] },
                ignoredDomains: { taxonomy?.current.ignoredDomains ?? [] },
                baseIntervals: DayAccounting.BaseIntervals(config: config)
            )
            let payload = Payload(try service.coverage(from: fromDay, to: toDay))
            try CLIOutput.printOrJSON(json: output.json, text: Self.text(payload), payload: payload)
        }

        static func text(_ payload: Payload) -> String {
            var lines = ["\(payload.from) to \(payload.to), \(payload.days) days", ""]
            lines += section("Project spans", payload.spans)
            lines.append("")
            lines += section("Each frame alone", payload.perFrame)
            return lines.joined(separator: "\n")
        }

        static func section(_ title: String, _ rule: Rule) -> [String] {
            func percent(_ part: Int, of total: Int) -> String {
                total > 0 ? String(format: "%.1f%%", Double(part) / Double(total) * 100) : "0.0%"
            }
            func reasons(_ minutes: [String: Int], of total: Int) -> [String] {
                minutes.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                    .map { "    \($0.key)  \($0.value) min (\(percent($0.value, of: total)))" }
            }
            var lines = [title]
            let unattributed = rule.screenMinutes - rule.screenAttributedMinutes
            lines.append("  screen    \(rule.screenMinutes) min, \(rule.screenAttributedMinutes) with a project, "
                + "\(percent(unattributed, of: rule.screenMinutes)) without")
            lines += reasons(rule.screenUnattributed, of: rule.screenMinutes)
            lines.append("  meetings  \(rule.meetingMinutes) min, \(rule.meetingAttributedMinutes) with a company")
            lines += reasons(rule.meetingUnattributed, of: rule.meetingMinutes)
            if !rule.byRule.isEmpty {
                lines.append("  by rule")
                lines += rule.byRule.sorted { $0.key < $1.key }.map { "    \($0.key)  \($0.value) min" }
            }
            lines.append("  \(rule.spans) spans, \(rule.absorbed) one-frame detours absorbed")
            return lines
        }
    }
}

// MARK: - Rules and assignments (#324)

extension ProjectsCommand {
    /// The corrector over this install's database and taxonomy file.
    static func corrector() throws -> ProjectCorrector {
        let config = try CLIConfig.load()
        return ProjectCorrector(
            db: try Database(dataDir: config.dataDir),
            taxonomy: try TaxonomyStore(dataDir: config.dataDir),
            baseIntervals: DayAccounting.BaseIntervals(config: config)
        )
    }

    /// Runs a correction, turning a refusal (an unknown project, a claimed value, a bad range)
    /// into one `error:` line, and prints its report.
    static func report(json: Bool, _ body: () throws -> ProjectCorrections.Report) throws {
        let report: ProjectCorrections.Report
        do {
            report = try body()
        } catch let error as ProjectCatalogError {
            throw CLIFailure.runtime(error.description)
        } catch let error as ProjectCorrectionError {
            throw CLIFailure.runtime(error.description)
        }
        try CLIOutput.printOrJSON(
            json: json, text: ProjectCorrections.lines(report).joined(separator: "\n"), payload: report
        )
    }

    /// Exactly one of `--domain`, `--repo`, `--url-prefix`.
    struct RuleValueOptions: ParsableArguments {
        @Option(help: "An email or web domain, such as acme.com. Covers its subdomains.")
        var domain: String?

        @Option(help: "A GitHub repo, owner/repo.")
        var repo: String?

        @Option(name: .customLong("url-prefix"), help: "A URL prefix. Its query and fragment are dropped.")
        var urlPrefix: String?

        /// `orAssignment` is set where `--assignment <id>` is the other way to name what to act on.
        func kindAndValue(
            allowingNone: Bool = false, orAssignment: Bool = false
        ) throws -> (kind: ProjectRuleKind, value: String)? {
            let given: [(ProjectRuleKind, String)] = [
                (.domain, domain), (.repo, repo), (.urlPrefix, urlPrefix),
            ].compactMap { kind, value in value.map { (kind, $0) } }
            if given.isEmpty, allowingNone { return nil }
            guard given.count == 1 else {
                throw ValidationError(orAssignment
                    ? "give exactly one of --domain, --repo, --url-prefix or --assignment <id>"
                    : "give exactly one of --domain, --repo or --url-prefix")
            }
            guard given[0].0.normalized(given[0].1) != nil else {
                throw ValidationError("\(given[0].0.flag) \"\(given[0].1)\" is not a usable value")
            }
            return given[0]
        }
    }

    struct RuleCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rule",
            abstract: "Say a domain, repo or URL prefix is one project, reaching past days.",
            subcommands: [RuleAddCommand.self, RuleListCommand.self, RuleRemoveCommand.self]
        )
    }

    struct RuleAddCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Add a rule, printing the minutes it moves before saving.",
            discussion: """
                A URL prefix beats a repo, a repo beats a domain, and any rule beats what \
                Worklens worked out on its own, including a meeting's company. Idle, locked and \
                asleep time never moves. --dry-run prints the same minutes and saves nothing.
                """
        )

        @OptionGroup var value: RuleValueOptions
        @Option(help: "The project: its key or any name it answers to.") var project: String
        @Flag(help: "Print the minutes that would move, and save nothing.") var dryRun = false
        @OptionGroup var output: JSONOutputOptions

        func run() throws {
            guard let (kind, raw) = try value.kindAndValue() else { return }
            let corrector = try ProjectsCommand.corrector()
            try ProjectsCommand.report(json: output.json) {
                try corrector.addRule(kind, raw, project: project, dryRun: dryRun)
            }
        }
    }

    struct RuleListCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list", abstract: "List your rules, then your assignments with their ids."
        )

        @OptionGroup var output: JSONOutputOptions

        func run() throws {
            let config = try CLIConfig.load()
            let taxonomy = try TaxonomyStore(dataDir: config.dataDir)
            let assignments = try ProjectAssignmentStore(try Database(dataDir: config.dataDir)).all()
            let list = ProjectCorrections.ruleList(taxonomy.projects, assignments: assignments)
            try CLIOutput.printOrJSON(
                json: output.json, text: ProjectCorrections.lines(list).joined(separator: "\n"), payload: list
            )
        }
    }

    struct RuleRemoveCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract: "Remove a rule, or an assignment by id, printing the minutes that move back."
        )

        @OptionGroup var value: RuleValueOptions
        @Option(help: "An assignment's id, from `rule list`.") var assignment: Int64?
        @Flag(help: "Print the minutes that would move, and save nothing.") var dryRun = false
        @OptionGroup var output: JSONOutputOptions

        func run() throws {
            let rule = try value.kindAndValue(allowingNone: assignment != nil, orAssignment: true)
            guard (rule == nil) != (assignment == nil) else {
                throw ValidationError("give one rule flag or --assignment, not both")
            }
            let corrector = try ProjectsCommand.corrector()
            try ProjectsCommand.report(json: output.json) {
                if let assignment { return try corrector.unassign(id: assignment, dryRun: dryRun) }
                guard let (kind, raw) = rule else { throw ValidationError("give one rule flag or --assignment") }
                return try corrector.removeRule(kind, raw, dryRun: dryRun)
            }
        }
    }

    struct AssignCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "assign",
            abstract: "Say one stretch of time was one project, printing the minutes it moves.",
            discussion: """
                --from and --to are local time, 2026-10-06T15:00, or carry an offset. The \
                stretch beats every rule; where two assignments overlap, the newer one wins. \
                Idle, locked and asleep time never moves. --dry-run saves nothing.
                """
        )

        @Option(help: "Where the stretch starts.") var from: LocalInstant
        @Option(help: "Where it ends. Not in the future.") var to: LocalInstant
        @Option(help: "The project: its key or any name it answers to.") var project: String
        @Flag(help: "Print the minutes that would move, and save nothing.") var dryRun = false
        @OptionGroup var output: JSONOutputOptions

        func validate() throws {
            guard to.date > from.date else { throw ValidationError("--to must come after --from") }
            guard to.date <= Date() else {
                throw ValidationError("--to is in the future; you can assign only time that has passed")
            }
        }

        func run() throws {
            let corrector = try ProjectsCommand.corrector()
            try ProjectsCommand.report(json: output.json) {
                try corrector.assign(from: from.date, to: to.date, project: project, dryRun: dryRun)
            }
        }
    }
}
