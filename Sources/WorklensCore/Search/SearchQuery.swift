import Foundation

/// Turns what a person typed into an FTS5 `MATCH` expression.
///
/// Pure and separate from the service because the interesting half is the escaping: FTS5's query
/// grammar treats `-`, `*`, `:`, `(` and `NOT` as operators, so a raw string typed at a shell —
/// `worklens search "yeti rambler 20oz"` — is as likely to be a syntax error as a query. Every
/// bare term is therefore re-emitted as a quoted phrase, which the tokenizer then splits exactly
/// as it split the indexed text; a double-quoted run in the input stays one phrase, and a
/// trailing `*` survives as a prefix search.
enum SearchQuery {
    static func matchExpression(_ raw: String) -> String? {
        let terms = split(raw).compactMap(quoted)
        return terms.isEmpty ? nil : terms.joined(separator: " ")
    }

    /// Splits on whitespace, except inside a double-quoted run. A `*` immediately after a term is
    /// kept attached so `quoted` can see it; an unterminated quote runs to the end of the input.
    private static func split(_ raw: String) -> [(text: String, prefix: Bool)] {
        var terms: [(String, Bool)] = []
        var current = ""
        var inQuotes = false

        func flush() {
            var text = current
            var prefix = false
            if !inQuotes, text.hasSuffix("*") {
                text.removeLast()
                prefix = true
            }
            if !text.isEmpty { terms.append((text, prefix)) }
            current = ""
        }

        for character in raw {
            if character == "\"" {
                if inQuotes { inQuotes = false; flush() } else { flush(); inQuotes = true }
            } else if character.isWhitespace, !inQuotes {
                flush()
            } else {
                current.append(character)
            }
        }
        flush()
        return terms
    }

    /// One term as an FTS5 phrase. A term the tokenizer would reduce to nothing — punctuation
    /// alone — is dropped rather than emitted as an empty phrase, which is a syntax error.
    private static func quoted(_ term: (text: String, prefix: Bool)) -> String? {
        guard term.text.unicodeScalars.contains(where: {
            CharacterSet.alphanumerics.contains($0)
        }) else { return nil }
        let escaped = term.text.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\"\(term.prefix ? "*" : "")"
    }
}
