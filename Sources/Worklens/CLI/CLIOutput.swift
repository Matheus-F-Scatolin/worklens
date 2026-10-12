import ArgumentParser
import Foundation

/// The one `--json` flag, shared by every command that has one.
///
/// An option group rather than a copied `@Flag` so that the spelling, the help line and the
/// default cannot drift apart across the commands that offer it — which is most of the reading
/// half of the CLI.
struct JSONOutputOptions: ParsableArguments {
    @Flag(name: .long, help: "Print JSON instead of the human-readable text.")
    var json: Bool = false
}

/// Printing a command's result in whichever of its two forms was asked for.
enum CLIOutput {
    /// Pretty, sorted and with real slashes: a dump a person reads as often as a script does, and
    /// `\/` in every path is the difference between the two.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static func jsonString<Payload: Encodable>(_ payload: Payload) throws -> String {
        String(decoding: try encoder.encode(payload), as: UTF8.self)
    }

    /// `text` and `payload` are autoclosures so that only the form actually being printed is
    /// built: several of these renderings walk the database.
    static func printOrJSON<Payload: Encodable>(
        json: Bool,
        text: @autoclosure () throws -> String,
        payload: @autoclosure () throws -> Payload
    ) throws {
        if json {
            print(try jsonString(try payload()))
        } else {
            print(try text())
        }
    }
}
