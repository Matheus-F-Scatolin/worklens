import ArgumentParser
import Foundation
import WorklensCore

/// Headless entry point: every pipeline stage is runnable without the menu bar.
///
/// Convention: this file holds only the root command. Each subcommand lives in its own file
/// `Sources/Worklens/CLI/<Name>Command.swift`, and its type goes into *one* of the three groups
/// below — not into a flat list. A new subcommand that belongs nowhere is a sign it wants a
/// different name, not a fourth group.
///
/// The root conforms to `AsyncParsableCommand` because subcommands that call the network
/// (`describe-pending`, `describe-one`) have an `async run()`; ArgumentParser silently skips those
/// when the root is only `ParsableCommand`.
struct WorklensCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "worklens",
        abstract: "Worklens: see where your day actually went.",
        // The prose paragraphs are single lines because the help screen rewraps them; the exit
        // table is the one place newlines are meant, and its rows are short enough to survive.
        discussion: "Most days you only need `worklens app` (the menu bar); Claude reads the record "
            + "through the MCP tools that `worklens mcp install` connects."
            + "\n\nA `--date` takes 2026-09-07, today, yesterday or -N days back. Write a negative "
            + "one with an equals sign, `--date=-3`, because a bare -3 looks like an option.\n\n"
            + CLIFailure.table,
        version: WorklensVersion.short,
        subcommands: [],
        groupedSubcommands: [
            CommandGroup(
                name: "Everyday",
                subcommands: [
                    AppCommand.self,
                    DescribePendingCommand.self,
                    TimelineCommand.self,
                    SearchCommand.self,
                    ProjectsCommand.self,
                    ShippedCommand.self,
                    AgentsCommand.self,
                ]
            ),
            CommandGroup(
                name: "Setup and integrations",
                subcommands: [
                    ConfigCommand.self,
                    ConfigExampleCommand.self,
                    SettingsCommand.self,
                    MCPCommand.self,
                    InstallEnvCommand.self,
                ]
            ),
            CommandGroup(
                name: "Diagnostics",
                subcommands: [
                    VersionCommand.self,
                    ConfigDumpCommand.self,
                    CaptureOnceCommand.self,
                    DescribeOneCommand.self,
                    ExpectRestartCommand.self,
                    RenderDemoCommand.self,
                ]
            ),
        ]
    )
}

/// Shared helper: load config for a CLI run, reporting a readable error instead of a trap.
enum CLIConfig {
    static func load() throws -> Config {
        try loadWithProvenance().config
    }

    /// Same load, keeping the record of which layer supplied each key (`config-dump`).
    static func loadWithProvenance() throws -> (config: Config, provenance: ConfigProvenance) {
        do {
            let loaded = try Config.loadWithProvenance()
            Log.configure(loaded.config)
            return loaded
        } catch let error as ConfigError {
            // Not a `ValidationError`: an unreadable `.env` is not a mistyped flag, and printing
            // the subcommand's usage block over it helps nobody (#158).
            throw CLIFailure.config("Invalid configuration: \(error.description)")
        }
    }
}
