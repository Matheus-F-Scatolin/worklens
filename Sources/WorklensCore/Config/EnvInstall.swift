import Foundation

/// What `worklens install-env` will do to the installed `.env`, worked out before a byte is
/// written (#129).
///
/// The command used to be a copy: `scripts/install_env_rewrite.py` opened the destination with
/// `"w"`, so every run silently threw away whatever the installed file had gained — a key typed
/// into Settings before #108 existed, a second machine's `DATA_DIR`, an API key that only lives
/// there. It is a **merge** now:
///
/// - a key only this checkout sets is added;
/// - a key only the installed file sets is kept;
/// - a key both set to different values is a *conflict*: the installed value stays, the
///   disagreement is printed as a three-column diff, and `--force` is what takes the checkout's;
/// - a key the checkout leaves *empty* — `GEMINI_API_KEY=`, which is what `.env.example` ships
///   and what a checkout looks like once the real keys live only in Application Support (#116) —
///   is not a value at all. It neither adds nor conflicts, so `--force` cannot blank an
///   installed key. That is `Config`'s own rule: the first *non-empty* layer wins.
///
/// The destination's own bytes — its comments, its order, its blank lines — are carried through
/// untouched; added keys go on the end under one comment line saying where they came from.
///
/// `DATA_DIR` keeps the pinning that is the whole point of the command (#34): a relative value
/// in the source is made absolute against the checkout before anything is compared, because the
/// copy is read from a different directory than it was written in.
public enum EnvInstall {
    /// One key both files set, differently. Values of secret keys arrive here already masked:
    /// the diff is printed to a terminal, and "they disagree" is the whole message.
    public struct Conflict: Sendable, Equatable {
        public let key: String
        /// This checkout's value, after `DATA_DIR` pinning.
        public let source: String
        /// The installed file's value.
        public let destination: String

        public init(key: String, source: String, destination: String) {
            self.key = key
            self.source = source
            self.destination = destination
        }
    }

    /// The whole outcome: the text to write, and everything the command has to tell the user.
    public struct Plan: Sendable, Equatable {
        /// Exactly what the destination file should contain afterwards.
        public let text: String
        /// Keys the checkout contributed that the installed file did not have, in file order.
        public let added: [String]
        /// Keys both files set differently, in file order.
        public let conflicts: [Conflict]
        /// The conflicting keys this plan resolved the checkout's way — every one of them under
        /// `--force`, and `DATA_DIR` alone when `--data-dir` named it explicitly.
        public let taken: [String]
        /// True when there was no installed file at all: a first install, not a merge.
        public let isNewFile: Bool
        /// The `DATA_DIR` the installed file will hold once this is written, resolved the way
        /// the app will read it. Nil when no layer here sets one, which leaves the app on its
        /// own default (#116).
        public let dataDir: String?
        /// The `DATA_DIR` the installed file held before, when this plan changes it.
        public let previousDataDir: String?

        public init(
            text: String,
            added: [String] = [],
            conflicts: [Conflict] = [],
            taken: [String] = [],
            isNewFile: Bool = false,
            dataDir: String? = nil,
            previousDataDir: String? = nil
        ) {
            self.text = text
            self.added = added
            self.conflicts = conflicts
            self.taken = taken
            self.isNewFile = isNewFile
            self.dataDir = dataDir
            self.previousDataDir = previousDataDir
        }

        /// Whether writing this plan changes anything on disk.
        public var changesFile: Bool { isNewFile || !added.isEmpty || !taken.isEmpty }

        /// Conflicts left at the installed value — what `--force` would change.
        public var kept: [Conflict] { conflicts.filter { !taken.contains($0.key) } }
    }

    /// Where a `DATA_DIR` that is not already absolute should end up.
    public struct Pin: Sendable, Equatable {
        /// Rewrite a relative `DATA_DIR` against this checkout, and append one when the file
        /// sets none. This is `make install-env`'s default.
        public static func checkout(_ url: URL) -> Pin { Pin(checkout: url, override: nil, enabled: true) }
        /// `--data-dir PATH`: pin here whatever either file says.
        public static func explicit(_ path: String, checkout: URL) -> Pin {
            Pin(checkout: checkout, override: path, enabled: true)
        }
        /// `--no-pin`: copy `DATA_DIR` through as written, or leave it unset.
        public static func off(checkout: URL) -> Pin { Pin(checkout: checkout, override: nil, enabled: false) }

        let checkout: URL
        let override: String?
        let enabled: Bool
    }

    public static let dataDirKey = "DATA_DIR"

    /// The note `--pin` leaves above a `DATA_DIR` it had to append.
    static let pinnedNote = """
        # Pinned by `worklens install-env`: the bundled app's working directory is `/`,
        # so a relative DATA_DIR here would not mean that checkout.
        """

    /// The comment that introduces keys taken from the checkout.
    static func addedNote(checkout: URL) -> String {
        "# Added by `worklens install-env` from \(checkout.path)."
    }

    // MARK: - Planning

    /// Works out the merge. Pure: it reads no files and writes none, which is what makes the
    /// rule testable and the command a thin shell around it.
    ///
    /// - Parameters:
    ///   - source: this checkout's `.env`.
    ///   - destination: the installed `.env`, or nil when there is not one yet.
    ///   - destinationDirectory: where the installed file lives, so a relative `DATA_DIR`
    ///     already in it resolves the way the app will read it.
    ///   - pin: what to do about `DATA_DIR`.
    ///   - force: take the checkout's value for every conflict.
    public static func plan(
        source: String,
        destination: String?,
        destinationDirectory: URL,
        pin: Pin,
        force: Bool = false
    ) -> Plan {
        let pinned = pinnedSource(source, pin: pin, destinationDirectory: destinationDirectory)
        let sourceValues = DotEnv.parse(pinned.text)
        let sourceOrder = keyOrder(pinned.text)

        guard let destination else {
            return Plan(
                text: pinned.text,
                added: sourceOrder,
                isNewFile: true,
                dataDir: pinned.dataDir
            )
        }

        let destinationValues = DotEnv.parse(destination)
        var added: [String] = []
        var conflicts: [Conflict] = []
        for key in sourceOrder {
            // An empty value in the checkout means "this file does not set this key" — the rule
            // `Config` itself layers by, where the first *non-empty* layer wins. Without it the
            // `GEMINI_API_KEY=` that `.env.example` ships would read as a disagreement with a
            // real installed key, and `--force` would write that blank straight over it: the
            // silent destruction of installed values this command exists to stop (#129).
            guard let mine = sourceValues[key], !mine.isEmpty else { continue }
            guard let theirs = destinationValues[key] else {
                added.append(key)
                continue
            }
            guard theirs != mine else { continue }
            conflicts.append(
                Conflict(key: key, source: display(key, mine), destination: display(key, theirs))
            )
        }

        // `--data-dir` is an instruction, not a disagreement between two files: someone typed
        // the path they want on the command line, so it wins its own key without `--force`.
        let taken: [String]
        if force {
            taken = conflicts.map(\.key)
        } else if pin.override != nil, conflicts.contains(where: { $0.key == EnvInstall.dataDirKey }) {
            taken = [EnvInstall.dataDirKey]
        } else {
            taken = []
        }

        var lines = lines(of: destination)
        for key in taken {
            // Belt and braces: nothing that reached `taken` has an empty source value, and a
            // blank must never overwrite a value the installed file already has.
            guard let value = sourceValues[key], !value.isEmpty else { continue }
            lines = rewrite(lines, key: key, value: value)
        }
        if !added.isEmpty {
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("")
            }
            lines.append(addedNote(checkout: pin.checkout))
            for key in added { lines.append("\(key)=\(sourceValues[key] ?? "")") }
        }
        let text = lines.joined(separator: "\n") + "\n"

        let before = resolvedDataDir(destination, directory: destinationDirectory)
        let after = resolvedDataDir(text, directory: destinationDirectory)
        return Plan(
            text: text,
            added: added,
            conflicts: conflicts,
            taken: taken,
            isNewFile: false,
            dataDir: after,
            previousDataDir: before == after ? nil : before
        )
    }

    /// The three-column diff, ready to print: `key · this checkout · installed`.
    public static func diffLines(_ conflicts: [Conflict]) -> [String] {
        guard !conflicts.isEmpty else { return [] }
        let keyWidth = max(3, conflicts.map(\.key.count).max() ?? 0)
        let sourceWidth = max(14, min(conflicts.map(\.source.count).max() ?? 0, 48))
        var lines = [
            "\(pad("key", keyWidth))  \(pad("this checkout", sourceWidth))  installed"
        ]
        for conflict in conflicts {
            lines.append(
                "\(pad(conflict.key, keyWidth))  \(pad(conflict.source, sourceWidth))  \(conflict.destination)"
            )
        }
        return lines
    }

    // MARK: - DATA_DIR

    /// The source text with `DATA_DIR` resolved the way the destination will have to read it,
    /// plus that resolved value.
    static func pinnedSource(
        _ text: String,
        pin: Pin,
        destinationDirectory: URL
    ) -> (text: String, dataDir: String?) {
        var resolved: String?
        var output: [String] = []
        for line in lines(of: text) {
            guard isAssignment(line, of: dataDirKey), let prefix = assignmentPrefix(line) else {
                output.append(line)
                continue
            }
            let value = DotEnv.parse(line)[dataDirKey] ?? ""
            if let override = pin.override {
                let expanded = expand(override) ?? override
                resolved = expanded
                output.append("\(prefix)\(expanded)")
            } else if !pin.enabled {
                // Copied through as written, so the destination's directory is what a relative
                // value will mean there — and that is what gets reported.
                resolved = value.isEmpty ? nil : resolve(value, against: destinationDirectory)
                output.append(line)
            } else if !value.isEmpty, !value.hasPrefix("/"), !value.hasPrefix("~") {
                let pinned = resolve(value, against: pin.checkout)
                resolved = pinned
                output.append("\(prefix)\(pinned)")
            } else {
                resolved = value.isEmpty ? nil : value
                output.append(line)
            }
        }
        if resolved == nil, pin.enabled {
            let value = pin.override.flatMap(expand)
                ?? pin.checkout.appendingPathComponent("data").path
            resolved = value
            if let last = output.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
                output.append("")
            }
            output.append(contentsOf: lines(of: pinnedNote))
            output.append("\(dataDirKey)=\(value)")
        }
        return (output.joined(separator: "\n") + "\n", resolved)
    }

    /// The `DATA_DIR` a `.env` text sets, resolved the way the app will read it: a relative path
    /// means "next to this file", not "next to whoever is running".
    static func resolvedDataDir(_ text: String, directory: URL) -> String? {
        guard let value = DotEnv.parse(text)[dataDirKey], !value.isEmpty else { return nil }
        return resolve(value, against: directory)
    }

    // MARK: - Line surgery

    /// True when this line assigns `key`, by `DotEnv`'s rules (optional `export `, key before
    /// the first `=`), and is not a comment.
    static func isAssignment(_ line: String, of key: String) -> Bool {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.isEmpty || text.hasPrefix("#") { return false }
        if text.hasPrefix("export ") || text.hasPrefix("export\t") {
            text = String(text.dropFirst("export".count)).trimmingCharacters(in: .whitespaces)
        }
        guard let eq = text.firstIndex(of: "=") else { return false }
        return String(text[text.startIndex..<eq]).trimmingCharacters(in: .whitespaces) == key
    }

    /// Everything up to and including the `=`, so a rewrite keeps the indentation and the
    /// `export ` the author wrote.
    static func assignmentPrefix(_ line: String) -> String? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        return String(line[line.startIndex...eq])
    }

    static func rewrite(_ lines: [String], key: String, value: String) -> [String] {
        lines.map { line in
            guard isAssignment(line, of: key), let prefix = assignmentPrefix(line) else { return line }
            return "\(prefix)\(value)"
        }
    }

    /// Every key a `.env` text assigns, in the order it assigns them, each once.
    static func keyOrder(_ text: String) -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        for line in lines(of: text) {
            let parsed = DotEnv.parse(line)
            guard let key = parsed.keys.first, !seen.contains(key) else { continue }
            seen.insert(key)
            order.append(key)
        }
        return order
    }

    // MARK: - Small helpers

    /// A value safe to print: masked for the keys `Config` calls secrets.
    static func display(_ key: String, _ value: String) -> String {
        secretKeys.contains(key) ? Config.mask(value) : value
    }

    static let secretKeys: Set<String> = Set(
        Config.keys.filter { $0.kind == .secret }.map(\.name)
    )

    static func expand(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        return Config.expandPath(path, cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).path
    }

    static func resolve(_ value: String, against directory: URL) -> String {
        Config.expandPath(value, cwd: directory).path
    }

    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    /// The lines of a file, keeping the empty ones — `split` drops them, and a `.env`'s blank
    /// lines are part of how it reads.
    static func lines(of text: String) -> [String] {
        var body = text.replacingOccurrences(of: "\r\n", with: "\n")
        if body.hasSuffix("\n") { body.removeLast() }
        if body.isEmpty { return [] }
        return body.components(separatedBy: "\n")
    }
}
