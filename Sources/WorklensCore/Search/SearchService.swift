import Foundation
import GRDB

/// One answer to "where did I see that": the frame that matched, what it was, and the words
/// around the match.
public struct SearchHit: Sendable, Equatable, Codable {
    /// The frame whose text matched — the best-ranked one when several collapsed into this hit.
    public var captureId: String
    public var day: String
    public var capturedAt: Date
    /// Which of the frame's four texts matched.
    public var kind: SearchKind
    /// FTS5 `snippet()` around the match, ellipsised at both ends.
    public var snippet: String
    /// From the frame's description, when it has one.
    public var appKey: String?
    public var appName: String?
    public var windowTitle: String?
    public var urlHost: String?
    /// The `activity_blocks` row the frame falls inside, when the day has been built.
    public var blockId: String?
    /// `captures.image_path`, relative to `DATA_DIR`, when the JPEG survived retention.
    public var imagePath: String?
    /// How many distinct frames collapsed into this hit — a 40-frame reading session reads as 40.
    public var frames: Int

    public init(
        captureId: String, day: String, capturedAt: Date, kind: SearchKind, snippet: String,
        appKey: String? = nil, appName: String? = nil, windowTitle: String? = nil,
        urlHost: String? = nil, blockId: String? = nil, imagePath: String? = nil, frames: Int = 1
    ) {
        self.captureId = captureId
        self.day = day
        self.capturedAt = capturedAt
        self.kind = kind
        self.snippet = snippet
        self.appKey = appKey
        self.appName = appName
        self.windowTitle = windowTitle
        self.urlHost = urlHost
        self.blockId = blockId
        self.imagePath = imagePath
        self.frames = frames
    }
}

/// An optional narrowing on a search: the project the describer named, or the app it was in
/// (#241). Both match case-insensitively on a substring, because the model is quoting a name it
/// read from `vocabulary` and not a database key.
public struct SearchFilters: Sendable, Equatable {
    public var project: String?
    public var app: String?

    public init(project: String? = nil, app: String? = nil) {
        self.project = project
        self.app = app
    }

    public var isEmpty: Bool { project == nil && app == nil }
}

/// A filtered search: what came back, and how much the filter kept out.
///
/// The second number is the point. A filter that silently returns nothing looks exactly like a
/// query nothing matched, and the model cannot tell the two apart without it.
public struct SearchResults: Sendable, Equatable {
    public var hits: [SearchHit]
    /// Screenshots that matched the query inside the same day range but fell outside the filter.
    public var excluded: Int

    public init(hits: [SearchHit], excluded: Int = 0) {
        self.hits = hits
        self.excluded = excluded
    }
}

/// One page of a search, and what is behind it (#244).
///
/// The second and third fields are why this exists: a results list that shows twenty hits out of
/// however many there were, and says neither number, tells the person their day holds twenty
/// matches. `total` counts collapsed results — the rows a person would count — and
/// `isTotalExact` is false when the read stopped at its own cap with rows still behind it, so a
/// header can say "more than" rather than a number it cannot stand behind.
public struct SearchPage: Sendable, Equatable {
    public var hits: [SearchHit]
    /// The results this page starts after.
    public var offset: Int
    public var total: Int
    public var isTotalExact: Bool
    /// Screenshots the query matched inside the same day range but the filter kept out.
    public var excluded: Int

    public init(
        hits: [SearchHit], offset: Int = 0, total: Int = 0, isTotalExact: Bool = true,
        excluded: Int = 0
    ) {
        self.hits = hits
        self.offset = offset
        self.total = total
        self.isTotalExact = isTotalExact
        self.excluded = excluded
    }

    /// How many results the list is showing, counting the pages before this one.
    public var shown: Int { offset + hits.count }
    public var hasMore: Bool { !isTotalExact || shown < total }
}

/// Queries `search_fts`. No model call is involved — every word searched is already on disk.
///
/// Also the body of the MCP server's `search` tool (#89); the CLI is one caller, not the feature.
public struct SearchService: Sendable {
    private let db: Database
    private let timeZone: TimeZone
    /// The project catalog, so a `project` filter that names an entry finds the frames the
    /// describer gave that entry's key (#315). Empty leaves the filter a plain substring match.
    private let projects: [ProjectEntry]

    public init(_ db: Database, timeZone: TimeZone = .current, projects: [ProjectEntry] = []) {
        self.db = db
        self.timeZone = timeZone
        self.projects = projects
    }

    /// Ranked best first. `days` is an inclusive `YYYY-MM-DD` range; nil searches everything.
    ///
    /// Rows are read best-first and then collapsed, so `limit` counts results a person would
    /// count. The read is capped well above `limit` because a single block can swallow dozens of
    /// rows; a query whose every hit lands in one block returns one result, not `limit` of them.
    public func search(
        query: String, days: ClosedRange<String>? = nil, limit: Int = 20
    ) throws -> [SearchHit] {
        try search(query: query, days: days, limit: limit, filters: SearchFilters()).hits
    }

    /// The same read, narrowed to a project or an app, and counting what the narrowing dropped.
    public func search(
        query: String, days: ClosedRange<String>? = nil, limit: Int = 20, filters: SearchFilters
    ) throws -> SearchResults {
        let found = try page(query: query, days: days, offset: 0, limit: limit, filters: filters)
        return SearchResults(hits: found.hits, excluded: found.excluded)
    }

    /// One page of the same read, and how many results are behind it (#244).
    ///
    /// `offset` counts collapsed results — the rows a person would count — so **Show more** asks
    /// for the next page by passing the number it already shows. The two calls above are this one
    /// at offset zero, and answer exactly what they answered before: the rows arrive best-first,
    /// so the first `limit` groups of an unlimited collapse are the groups a collapse limited to
    /// `limit` kept, with the same frame counts. `worklens search` and the MCP `search` tool
    /// print the same bytes for the same query as a result.
    public func page(
        query: String, days: ClosedRange<String>? = nil, offset: Int = 0, limit: Int = 20,
        filters: SearchFilters = SearchFilters()
    ) throws -> SearchPage {
        guard limit > 0, offset >= 0, let match = SearchQuery.matchExpression(query) else {
            return SearchPage(hits: [])
        }
        let excluded = filters.isEmpty ? 0 : try excludedCount(match: match, days: days, filters: filters)
        let wanted = offset + limit
        let scan = max(wanted * 20, 200)
        let candidates = try rows(match: match, days: days, scan: scan, filters: filters)
        guard !candidates.isEmpty else {
            return SearchPage(hits: [], offset: offset, excluded: excluded)
        }
        let blocks = try blockIndex(days: Set(candidates.map(\.day)))
        let all = collapse(candidates, blocks: blocks, limit: Int.max)
        let hits = offset < all.count ? Array(all[offset..<min(all.count, wanted)]) : []
        return SearchPage(
            hits: hits,
            offset: offset,
            total: all.count,
            // The read is capped, and a cap it reached is a cap that may have cut rows off. The
            // total is then a floor, and the header has to say so — but only while the page
            // itself filled. The cap counts rows and the total counts collapsed results, so a
            // query whose every hit lands in one long block fills the scan and still runs out of
            // results before the page is full; saying "more than three" about exactly three, and
            // offering a Show more that has nothing to add, misstates the person's own data in
            // the other direction.
            isTotalExact: candidates.count < scan || all.count < wanted,
            excluded: excluded
        )
    }

    // MARK: - Internals

    private struct Candidate {
        var captureId: String
        var day: String
        var capturedAt: Date
        var kind: SearchKind
        var snippet: String
        var appKey: String?
        var appName: String?
        var windowTitle: String?
        var urlHost: String?
        var imagePath: String?
    }

    private struct Block {
        var id: String
        var startAt: Date
        var endAt: Date
    }

    /// The weighted bm25 sort lives in SQL so SQLite can stop at `scan` rows.
    /// One SQL boolean the filter is true of, plus its arguments. `project` is read out of the
    /// description's `details_json`, which is where the describer's project hint lives, and
    /// matches its d5 `project_key` too (#315), so a frame that named only a key is found. When the
    /// filter names a catalog entry by key, name or alias, every key that entry answers to counts:
    /// its own, and the old keys a merge left on it as aliases. `app` matches either the app name
    /// macOS reported or the taxonomy key the describer resolved.
    private func filterSQL(_ filters: SearchFilters) -> (sql: String, arguments: [String]) {
        var clauses: [String] = []
        var values: [String] = []
        if let filter = filters.project {
            let project = filter.lowercased()
            let entry = ProjectEntry.lookup(key: filter, in: projects)
            let keys = entry.map { Set(([$0.key] + ($0.aliases ?? [])).map { $0.lowercased() }).sorted() } ?? []
            let keyed = keys.isEmpty ? "" : """

                               OR lower(json_extract(dp.details_json, '$.project_key')) IN (\(keys.map { _ in "?" }.joined(separator: ", ")))
                """
            clauses.append("""
                EXISTS (SELECT 1 FROM descriptions dp WHERE dp.capture_id = search_fts.capture_id
                          AND (lower(COALESCE(json_extract(dp.details_json, '$.project_hint'), '')) LIKE ?
                               OR lower(COALESCE(json_extract(dp.details_json, '$.project_key'), '')) LIKE ?\(keyed)))
                """)
            values.append("%\(project)%")
            values.append("%\(project)%")
            values.append(contentsOf: keys)
        }
        if let app = filters.app?.lowercased() {
            clauses.append("""
                (lower(COALESCE(c.app_name, '')) LIKE ?
                   OR EXISTS (SELECT 1 FROM descriptions da WHERE da.capture_id = search_fts.capture_id
                                AND lower(da.app_key) LIKE ?))
                """)
            values.append("%\(app)%")
            values.append("%\(app)%")
        }
        guard !clauses.isEmpty else { return ("1", []) }
        return ("(\(clauses.joined(separator: " AND ")))", values)
    }

    /// Screenshots the query matched and the filter kept out, counted once each.
    private func excludedCount(
        match: String, days: ClosedRange<String>?, filters: SearchFilters
    ) throws -> Int {
        let filter = filterSQL(filters)
        let sql = """
            SELECT COUNT(DISTINCT search_fts.capture_id)
            FROM search_fts
            JOIN captures c ON c.id = search_fts.capture_id
            WHERE search_fts MATCH ?
              AND (? IS NULL OR search_fts.day >= ?)
              AND (? IS NULL OR search_fts.day <= ?)
              AND NOT \(filter.sql)
            """
        let lower = days?.lowerBound
        let upper = days?.upperBound
        var arguments: [(any DatabaseValueConvertible)?] = [match, lower, lower, upper, upper]
        arguments.append(contentsOf: filter.arguments.map { $0 as (any DatabaseValueConvertible)? })
        return try db.writer.read { db in
            try Int.fetchOne(db, sql: sql, arguments: StatementArguments(arguments)) ?? 0
        }
    }

    private func rows(
        match: String, days: ClosedRange<String>?, scan: Int, filters: SearchFilters = SearchFilters()
    ) throws -> [Candidate] {
        let filter = filterSQL(filters)
        let weights = SearchKind.allCases
            .map { "WHEN '\($0.rawValue)' THEN \($0.rankWeight)" }
            .joined(separator: " ")
        // No alias on `search_fts`: SQLite resolves `MATCH`, `bm25()` and `snippet()` against the
        // table name itself, and an aliased FTS5 table fails to compile the query.
        let sql = """
            SELECT search_fts.capture_id AS capture_id,
                   search_fts.day AS day,
                   search_fts.kind AS kind,
                   snippet(search_fts, 0, '', '', '…', 20) AS snippet,
                   bm25(search_fts) * (CASE search_fts.kind \(weights) ELSE 1.0 END) AS score,
                   c.captured_at AS captured_at, c.app_name AS app_name,
                   c.window_title AS window_title, c.url_host AS url_host,
                   c.image_path AS image_path,
                   (SELECT d.app_key FROM descriptions d
                     WHERE d.capture_id = search_fts.capture_id
                     ORDER BY d.created_at DESC LIMIT 1) AS app_key
            FROM search_fts
            JOIN captures c ON c.id = search_fts.capture_id
            WHERE search_fts MATCH ?
              AND (? IS NULL OR search_fts.day >= ?)
              AND (? IS NULL OR search_fts.day <= ?)
              AND \(filter.sql)
            ORDER BY score
            LIMIT ?
            """
        let lower = days?.lowerBound
        let upper = days?.upperBound
        var values: [(any DatabaseValueConvertible)?] = [match, lower, lower, upper, upper]
        values.append(contentsOf: filter.arguments.map { $0 as (any DatabaseValueConvertible)? })
        values.append(scan)
        return try db.writer.read { db in
            try Row.fetchAll(
                db, sql: sql, arguments: StatementArguments(values)
            ).map { row in
                Candidate(
                    captureId: row["capture_id"],
                    day: row["day"],
                    capturedAt: row["captured_at"],
                    kind: SearchKind(rawValue: row["kind"]) ?? .ax,
                    snippet: row["snippet"],
                    appKey: row["app_key"],
                    appName: row["app_name"],
                    windowTitle: row["window_title"],
                    urlHost: row["url_host"],
                    imagePath: row["image_path"]
                )
            }
        }
    }

    private func blockIndex(days: Set<String>) throws -> [String: [Block]] {
        guard !days.isEmpty else { return [:] }
        let ordered = days.sorted()
        let holes = databaseQuestionMarks(count: ordered.count)
        let rows = try db.writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, day, start_at, end_at FROM activity_blocks
                    WHERE day IN (\(holes)) AND source = 'screen'
                    ORDER BY start_at
                    """,
                arguments: StatementArguments(ordered)
            )
        }
        var index: [String: [Block]] = [:]
        for row in rows {
            let day: String = row["day"]
            index[day, default: []].append(
                Block(id: row["id"], startAt: row["start_at"], endAt: row["end_at"])
            )
        }
        return index
    }

    /// Rows arrive best-first; the first row of a group therefore supplies the hit's snippet, its
    /// frame and its kind, and later rows only add to the frame count. Frames of one block share a
    /// group so a long reading session is one result; a frame the day's blocks have not been built
    /// for stands on its own, keyed by its own id.
    private func collapse(
        _ candidates: [Candidate], blocks: [String: [Block]], limit: Int
    ) -> [SearchHit] {
        var hits: [SearchHit] = []
        var groupIndex: [String: Int] = [:]
        var counted: [String: Set<String>] = [:]

        for candidate in candidates {
            let blockId = blocks[candidate.day]?.first {
                $0.startAt <= candidate.capturedAt && candidate.capturedAt <= $0.endAt
            }?.id
            let key = blockId.map { "block:\($0)" } ?? "capture:\(candidate.captureId)"

            if let existing = groupIndex[key] {
                if counted[key]?.insert(candidate.captureId).inserted == true {
                    hits[existing].frames += 1
                }
                continue
            }
            guard hits.count < limit else { continue }
            groupIndex[key] = hits.count
            counted[key] = [candidate.captureId]
            hits.append(SearchHit(
                captureId: candidate.captureId,
                day: candidate.day,
                capturedAt: candidate.capturedAt,
                kind: candidate.kind,
                snippet: candidate.snippet,
                appKey: candidate.appKey,
                appName: candidate.appName,
                windowTitle: candidate.windowTitle,
                urlHost: candidate.urlHost,
                blockId: blockId,
                imagePath: candidate.imagePath,
                frames: 1
            ))
        }
        return hits
    }
}
