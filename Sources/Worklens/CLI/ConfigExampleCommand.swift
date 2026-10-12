import ArgumentParser
import WorklensCore

/// Prints `.env.example` from the key registry. The checked-in file is this output byte for
/// byte (`EnvExampleTests` fails otherwise), so after adding a key:
///
///     swift run Worklens config-example > .env.example
struct ConfigExampleCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config-example",
        abstract: "Print .env.example, generated from the key registry."
    )

    @Flag(
        name: .long,
        help: "Print the starter .env the app writes itself on a first run instead (#116)."
    )
    var firstRun = false

    func run() {
        print(firstRun ? EnvTemplate.text : EnvExample.render(), terminator: "")
    }
}
