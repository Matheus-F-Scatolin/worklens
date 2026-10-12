import ArgumentParser
import Foundation
import WorklensCore

/// `worklens install-env` — point an installed app at this checkout (#129).
///
/// This was `scripts/install-env.sh` calling a Python rewriter that opened the destination with
/// `"w"`. It is Swift now, it shares `DotEnv` with the loader that will read the result, and it
/// **merges** instead of copying: the installed file keeps every key it already sets, this
/// checkout's new keys are added, and a key the two disagree about is printed as a three-column
/// diff and left alone unless `--force` says otherwise. `scripts/install-env.sh` is a wrapper
/// around this command, so `make install-env`, `README` and `scripts/setup.sh` all still work.
///
/// It never prompts. `make setup` and `scripts/update.sh` run it with no terminal attached, and
/// a question nobody can answer is how an unattended step hangs — a refused clobber is a
/// printed diff and exit 0, not a prompt.
struct InstallEnvCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-env",
        abstract: "Merge this checkout's .env into the one an installed Worklens reads.",
        discussion: """
            Merges ./.env into ~/Library/Application Support/Worklens/.env, which is where a
            bundled app looks. Keys only the installed file sets are kept, keys only this
            checkout sets are added, and a key both set differently is listed and left at the
            installed value: `--force` takes this checkout's instead.

            DATA_DIR is pinned to an absolute path on the way in, because the copy is read from
            a different directory than it was written in and a bundled app's working directory
            is `/`.
            """
    )

    @Option(name: .long, help: "Pin DATA_DIR to PATH instead of this checkout's ./data.")
    var dataDir: String?

    @Flag(name: .long, help: "Leave DATA_DIR exactly as written, pinning nothing.")
    var noPin = false

    @Flag(name: .long, help: "Take this checkout's value for every key the two files disagree about.")
    var force = false

    @Option(name: .long, help: "The .env to merge from (default: ./.env).")
    var from: String?

    @Option(
        name: .long,
        help: "The .env to merge into (default: ~/Library/Application Support/Worklens/.env)."
    )
    var dest: String?

    func run() throws {
        if dataDir != nil, noPin {
            throw ValidationError("--data-dir and --no-pin ask for opposite things")
        }
        let cwd = Config.currentDirectory
        let source = from.map { Config.expandPath($0, cwd: cwd) }
            ?? cwd.appendingPathComponent(".env")
        let checkout = source.deletingLastPathComponent()
        // Explicit because `HOME` is not enough: Foundation resolves the home directory from
        // the password database, so a test or a script cannot redirect this by exporting HOME.
        let destination = dest.map { Config.expandPath($0, cwd: cwd) } ?? Config.appSupportEnvURL()

        guard let sourceText = try? String(contentsOf: source, encoding: .utf8) else {
            throw ValidationError("no .env at \(source.path) (cp .env.example .env)")
        }
        let destinationText = try? String(contentsOf: destination, encoding: .utf8)

        let pin: EnvInstall.Pin
        if let dataDir {
            pin = .explicit(dataDir, checkout: checkout)
        } else if noPin {
            pin = .off(checkout: checkout)
        } else {
            pin = .checkout(checkout)
        }

        let plan = EnvInstall.plan(
            source: sourceText,
            destination: destinationText,
            destinationDirectory: destination.deletingLastPathComponent(),
            pin: pin,
            force: force
        )

        if plan.changesFile {
            try write(plan.text, to: destination)
            print(plan.isNewFile ? "installed \(destination.path)" : "merged into \(destination.path)")
        } else {
            print("no change to \(destination.path)")
        }

        if !plan.added.isEmpty {
            print("added from this checkout: \(plan.added.joined(separator: ", "))")
        }
        if !plan.taken.isEmpty {
            print("took this checkout's value for: \(plan.taken.joined(separator: ", "))")
        }
        report(plan.kept)

        if let dataDir = plan.dataDir {
            print("DATA_DIR=\(dataDir)")
        } else {
            print(
                "DATA_DIR is not set here; the app uses its own default "
                    + "(~/Library/Application Support/Worklens/data)"
            )
        }
        if let previous = plan.previousDataDir {
            print(
                "note: this replaces DATA_DIR=\(previous). Captures already recorded there stay "
                    + "where they are."
            )
        }
    }

    /// The three-column diff, and the one sentence that says what to do about it. Printed to
    /// stdout with the rest: this is the result of the command, not a failure of it.
    private func report(_ kept: [EnvInstall.Conflict]) {
        guard !kept.isEmpty else { return }
        print("")
        print(
            "kept the installed value for \(kept.count) "
                + "key\(kept.count == 1 ? "" : "s") this checkout sets differently:"
        )
        for line in EnvInstall.diffLines(kept) { print("  \(line)") }
        print("re-run with --force to take this checkout's values instead.")
    }

    /// 0600 in a 0700 directory, the same as every other file Worklens writes there: the
    /// destination is where API keys live.
    private func write(_ text: String, to url: URL) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
