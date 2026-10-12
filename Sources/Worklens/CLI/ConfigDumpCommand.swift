import ArgumentParser
import WorklensCore

struct ConfigDumpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config-dump",
        abstract: "Print every configuration key, its resolved value and where it came from."
    )

    @OptionGroup var output: JSONOutputOptions

    /// The rendering itself lives in `ConfigDumpText` since #156. `--json` (#158) is
    /// `[{key, value, source}]` from the same rows — secrets are masked in `Config.dumpLines`, so
    /// both forms mask them identically.
    func run() throws {
        let (config, provenance) = try CLIConfig.loadWithProvenance()
        try CLIOutput.printOrJSON(
            json: output.json,
            text: ConfigDumpText.render(config: config, provenance: provenance),
            payload: ConfigDumpText.rows(config: config, provenance: provenance)
        )
    }
}
