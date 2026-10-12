import Foundation

/// Codex's `~/.codex/config.toml`, the one client file that is not JSON.
///
/// Its servers are tables: `[mcp_servers.worklens]` with `command`, `args` and `env` under it.
/// There is no TOML parser in Foundation, and a full one is far more than this needs, so this
/// reads and edits the file as lines: it finds the tables whose header is `mcp_servers.<name>`
/// (and their subtables, such as `.env`), reads the three keys out of them, and on a write
/// replaces exactly those lines. Every other byte in the file stays where it was — a stronger
/// promise than the JSON writer can make, which re-serializes the whole object.
///
/// The one thing it will not do is guess. Servers written some other way — an inline
/// `mcp_servers = { … }`, dotted keys, or keys directly under a bare `[mcp_servers]` — are valid
/// TOML that a line edit could turn invalid, so a write refuses with `unmergeable` instead.
enum MCPTOML {
    // MARK: Reading

    static func parse(_ text: String) -> MCPClientConfig.Entry {
        let file = File(text)
        let servers = file.servers
        let named = servers[MCPClientConfig.serverName]
        let byCommand = servers.keys.sorted().lazy.compactMap { servers[$0] }.first {
            $0.command?.hasSuffix("/Worklens") == true
        }
        guard let server = named ?? byCommand else {
            if let why = file.unsupported { return .unreadable(why) }
            return .notConfigured
        }
        guard let command = server.command else {
            return .unreadable("the worklens entry has no \"command\"")
        }
        return .configured(command: command, args: server.args, env: server.env)
    }

    static func installedKey(in text: String) -> String? {
        let servers = File(text).servers
        if servers[MCPClientConfig.serverName] != nil { return MCPClientConfig.serverName }
        return renamedKey(in: servers)
    }

    /// Same rule as the JSON side's `renamedEntryKey`: no `worklens` table, but one that launches
    /// a binary called `Worklens`.
    static func renamedKey(in servers: [String: Server]) -> String? {
        guard servers[MCPClientConfig.serverName] == nil else { return nil }
        return servers.keys.sorted().first { servers[$0]?.command?.hasSuffix("/Worklens") == true }
    }

    // MARK: Writing

    /// The file with `key`'s tables replaced by `plan`, or with them appended when there are none.
    static func installing(_ plan: MCPClientConfig.Plan, into text: String) throws -> String {
        let file = File(text)
        if let why = file.unsupported { throw MCPClientConfig.InstallError.unmergeable(why) }
        let key = renamedKey(in: file.servers) ?? MCPClientConfig.serverName
        let block = entry(plan, key: key)
        var lines = file.lines
        let owned = file.lineRanges(of: key)
        if let first = owned.first {
            for range in owned.reversed() { lines.removeSubrange(range) }
            lines.insert(contentsOf: block + [""], at: first.lowerBound)
        } else {
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            if !lines.isEmpty { lines.append("") }
            lines.append(contentsOf: block)
        }
        return joined(lines)
    }

    /// The file without `key`'s tables, or nil when it has none.
    static func removing(key: String, from text: String) throws -> String? {
        let file = File(text)
        let owned = file.lineRanges(of: key)
        guard !owned.isEmpty else { return nil }
        var lines = file.lines
        for range in owned.reversed() { lines.removeSubrange(range) }
        return joined(lines)
    }

    /// `[mcp_servers.worklens]` and its three keys. The environment goes inline, so the entry is
    /// one table and a removal has one thing to find.
    static func entry(_ plan: MCPClientConfig.Plan, key: String) -> [String] {
        var lines = [
            "[mcp_servers.\(bareOrQuoted(key))]",
            "command = \(quoted(plan.command))",
            "args = [\(plan.args.map(quoted).joined(separator: ", "))]",
        ]
        if !plan.env.isEmpty {
            let pairs = plan.env.keys.sorted().map { "\(bareOrQuoted($0)) = \(quoted(plan.env[$0]!))" }
            lines.append("env = { \(pairs.joined(separator: ", ")) }")
        }
        return lines
    }

    private static func joined(_ lines: [String]) -> String {
        var lines = lines
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }

    static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    private static func bareOrQuoted(_ key: String) -> String {
        let bare = !key.isEmpty && key.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" || $0 == "-"
        }
        return bare ? key : quoted(key)
    }

    // MARK: The file, as tables

    struct Server: Equatable {
        var command: String?
        var args: [String] = []
        var env: [String: String] = [:]
    }

    /// One `[header]` and the lines under it.
    struct Table {
        let path: [String]
        /// The header through its last pair and the blank lines after it. A comment after the
        /// last pair is left out: it is as likely to introduce the next table as to end this one,
        /// and a removal that took somebody's note with it would be the worse mistake.
        let range: Range<Int>
        /// `key = value` pairs, a value spanning lines joined into one.
        let pairs: [(key: [String], value: String)]
    }

    struct File {
        let lines: [String]
        let tables: [Table]
        /// Key/value pairs before the first header.
        let root: [(key: [String], value: String)]

        init(_ text: String) {
            var lines = text.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            let cleaned = lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
            self.lines = cleaned

            var tables: [Table] = []
            var root: [(key: [String], value: String)] = []
            var index = 0
            typealias Open = (path: [String], start: Int, end: Int, pairs: [(key: [String], value: String)])
            func close(_ open: Open, at next: Int) -> Table {
                var end = open.end
                while end < next, cleaned[end].trimmingCharacters(in: .whitespaces).isEmpty { end += 1 }
                return Table(path: open.path, range: open.start..<end, pairs: open.pairs)
            }
            var current: Open?
            while index < cleaned.count {
                let line = cleaned[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("["), let path = MCPTOML.header(trimmed) {
                    if let open = current { tables.append(close(open, at: index)) }
                    current = (path, index, index + 1, [])
                    index += 1
                    continue
                }
                // A value can run over several lines (a multi-line array or string), so a
                // pair takes as many as it needs before the next header is looked for.
                var consumed = 1
                if let pair = MCPTOML.pair(startingAt: index, in: cleaned, consumed: &consumed) {
                    if current == nil {
                        root.append(pair)
                    } else {
                        current!.pairs.append(pair)
                        current!.end = index + consumed
                    }
                }
                index += consumed
            }
            if let open = current { tables.append(close(open, at: cleaned.count)) }
            self.tables = tables
            self.root = root
        }

        /// Every server declared as `[mcp_servers.<name>]`, with `.env` subtables folded in.
        var servers: [String: Server] {
            var servers: [String: Server] = [:]
            for table in tables where table.path.count >= 2 && table.path[0] == "mcp_servers" {
                let name = table.path[1]
                var server = servers[name] ?? Server()
                if table.path.count == 2 {
                    for pair in table.pairs where pair.key.count == 1 {
                        switch pair.key[0] {
                        case "command": server.command = MCPTOML.string(pair.value) ?? server.command
                        case "args": server.args = MCPTOML.strings(pair.value) ?? server.args
                        case "env": server.env.merge(MCPTOML.inlineTable(pair.value) ?? [:]) { $1 }
                        default: break
                        }
                    }
                    // `env.KEY = "value"`, the dotted spelling of the same thing.
                    for pair in table.pairs where pair.key.count == 2 && pair.key[0] == "env" {
                        if let value = MCPTOML.string(pair.value) { server.env[pair.key[1]] = value }
                    }
                } else if table.path.count == 3 && table.path[2] == "env" {
                    for pair in table.pairs where pair.key.count == 1 {
                        if let value = MCPTOML.string(pair.value) { server.env[pair.key[0]] = value }
                    }
                }
                servers[name] = server
            }
            return servers
        }

        /// Why a line edit would not be safe here, or nil when it would.
        var unsupported: String? {
            let form = "Codex's mcp_servers are written in a form Worklens does not edit"
            if root.contains(where: { $0.key.first == "mcp_servers" }) { return form }
            for table in tables {
                if table.path == ["mcp_servers"], !table.pairs.isEmpty { return form }
                // `[mcp_servers.x]` with `env.KEY = …` or `tools.y = …` under it is fine to
                // read around, but dotted keys that reach back up into mcp_servers are not.
                if table.path.first != "mcp_servers",
                   table.pairs.contains(where: { $0.key.first == "mcp_servers" }) { return form }
            }
            return nil
        }

        /// The line ranges of every table that belongs to `key`: its own and its subtables.
        func lineRanges(of key: String) -> [Range<Int>] {
            tables.filter { $0.path.count >= 2 && $0.path[0] == "mcp_servers" && $0.path[1] == key }
                .map(\.range)
        }
    }

    // MARK: Scanning

    /// `[a.b."c d"]` → `["a", "b", "c d"]`; nil for `[[array tables]]` and for anything that is
    /// not a header at all. An array-of-tables header still ends the table before it, so it is
    /// returned as a path no server can match.
    static func header(_ trimmed: String) -> [String]? {
        if trimmed.hasPrefix("[[") {
            guard let close = trimmed.range(of: "]]") else { return nil }
            let inner = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<close.lowerBound]
            return ["[["] + (keyPath(String(inner)) ?? [])
        }
        var inner = ""
        var quote: Character?
        for character in trimmed.dropFirst() {
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "]" {
                return keyPath(inner)
            }
            inner.append(character)
        }
        return nil
    }

    /// Splits a dotted key on the dots outside quotes and unquotes each part.
    static func keyPath(_ raw: String) -> [String]? {
        var parts: [String] = []
        var part = ""
        var quote: Character?
        var escaped = false
        for character in raw {
            if let open = quote {
                if open == "\"" && escaped { part.append(character); escaped = false; continue }
                if open == "\"" && character == "\\" { escaped = true; continue }
                if character == open { quote = nil; continue }
                part.append(character)
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "." {
                parts.append(part.trimmingCharacters(in: .whitespaces))
                part = ""
            } else {
                part.append(character)
            }
        }
        guard quote == nil else { return nil }
        parts.append(part.trimmingCharacters(in: .whitespaces))
        return parts.contains(where: \.isEmpty) ? nil : parts
    }

    /// `key = value`, with the value continued onto following lines until its brackets, braces
    /// and triple quotes close. Nil for a blank line, a comment, or anything without an `=`.
    static func pair(
        startingAt index: Int, in lines: [String], consumed: inout Int
    ) -> (key: [String], value: String)? {
        consumed = 1
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = equalsSign(in: trimmed),
              let key = keyPath(String(trimmed[..<equals]))
        else { return nil }
        var value = String(trimmed[trimmed.index(after: equals)...])
        while !isComplete(value), index + consumed < lines.count {
            value += "\n" + lines[index + consumed]
            consumed += 1
        }
        return (key, value.trimmingCharacters(in: .whitespaces))
    }

    private static func equalsSign(in text: String) -> String.Index? {
        var quote: Character?
        for index in text.indices {
            let character = text[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "=" {
                return index
            }
        }
        return nil
    }

    /// Whether a value's brackets and multi-line strings are all closed.
    private static func isComplete(_ value: String) -> Bool {
        var depth = 0
        var scanner = Scanner(value)
        while let token = scanner.next() {
            switch token {
            case .open: depth += 1
            case .close: depth -= 1
            case .comment: scanner.skipLine()
            case .string, .other, .comma, .equals: break
            case .unterminated: return false
            }
        }
        return depth <= 0
    }

    /// A single string value, basic or literal, with a trailing comment allowed.
    static func string(_ value: String) -> String? {
        var scanner = Scanner(value)
        guard case .string(let text)? = scanner.next() else { return nil }
        return text
    }

    /// `["a", 'b']`, over as many lines as it takes. Nil when it is not an array of strings.
    static func strings(_ value: String) -> [String]? {
        var scanner = Scanner(value)
        guard case .open("[")? = scanner.next() else { return nil }
        var out: [String] = []
        while let token = scanner.next() {
            switch token {
            case .string(let text): out.append(text)
            case .comma: continue
            case .comment: scanner.skipLine()
            case .close("]"): return out
            default: return nil
            }
        }
        return nil
    }

    /// `{ KEY = "value", "OTHER KEY" = 'value' }`. Nil when it is not a table of strings.
    static func inlineTable(_ value: String) -> [String: String]? {
        var scanner = Scanner(value)
        guard case .open("{")? = scanner.next() else { return nil }
        var out: [String: String] = [:]
        var key: String?
        while let token = scanner.next() {
            switch token {
            case .other(let word) where key == nil: key = word
            case .string(let text) where key == nil: key = text
            case .equals: continue
            case .string(let text):
                guard let name = key else { return nil }
                out[name] = text
                key = nil
            case .comma: continue
            case .close("}"): return out
            default: return nil
            }
        }
        return nil
    }

    /// Just enough of TOML's lexer for the values above.
    struct Scanner {
        enum Token: Equatable {
            case string(String), open(Character), close(Character)
            case comma, equals, comment, other(String), unterminated
        }

        private let characters: [Character]
        private var index = 0

        init(_ text: String) { characters = Array(text) }

        mutating func skipLine() {
            while index < characters.count, characters[index] != "\n" { index += 1 }
        }

        mutating func next() -> Token? {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            guard index < characters.count else { return nil }
            let character = characters[index]
            switch character {
            case "[", "{": index += 1; return .open(character)
            case "]", "}": index += 1; return .close(character)
            case ",": index += 1; return .comma
            case "=": index += 1; return .equals
            case "#": index += 1; return .comment
            case "\"", "'": return quotedString(character)
            default:
                var word = ""
                while index < characters.count,
                      !characters[index].isWhitespace,
                      !"[]{},=#\"'".contains(characters[index]) {
                    word.append(characters[index]); index += 1
                }
                return .other(word)
            }
        }

        private mutating func quotedString(_ quote: Character) -> Token {
            let triple = index + 2 < characters.count
                && characters[index + 1] == quote && characters[index + 2] == quote
            index += triple ? 3 : 1
            if triple, index < characters.count, characters[index] == "\n" { index += 1 }
            var text = ""
            while index < characters.count {
                let character = characters[index]
                if character == quote {
                    if !triple { index += 1; return .string(text) }
                    if index + 2 < characters.count,
                       characters[index + 1] == quote, characters[index + 2] == quote {
                        index += 3; return .string(text)
                    }
                }
                // A single-line string that never closes is a broken line, not the start of a
                // longer value: it ends here rather than swallowing the rest of the file.
                if !triple && character == "\n" { return .string(text) }
                if quote == "\"" && character == "\\" && index + 1 < characters.count {
                    index += 1
                    switch characters[index] {
                    case "n": text.append("\n")
                    case "t": text.append("\t")
                    case "r": text.append("\r")
                    case "\"": text.append("\"")
                    case "\\": text.append("\\")
                    case "u", "U":
                        let length = characters[index] == "u" ? 4 : 8
                        let hex = String(characters[(index + 1)..<min(index + 1 + length, characters.count)])
                        if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                            text.unicodeScalars.append(scalar)
                        }
                        index += length
                    default: text.append(characters[index])
                    }
                    index += 1
                    continue
                }
                text.append(character)
                index += 1
            }
            return triple ? .unterminated : .string(text)
        }
    }
}
