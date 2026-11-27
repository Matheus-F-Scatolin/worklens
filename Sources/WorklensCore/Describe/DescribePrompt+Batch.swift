import Foundation

/// d6: several screenshots in one request (`SUMMARY_BATCH`).
///
/// The prompt lists each screenshot in capture order with its own time, app, title, URL, window
/// text and meeting flag, under a label ("Screenshot 3 of 7, 14:32:10") that the describers also
/// put next to its picture. The run context and the project list are said once, for the batch.
/// The answer is `{ "screenshots": [ { "id": …, <one screenshot's fields> } ] }`, and each id
/// is a capture id the schema names, so the worker can tell which summary is whose.
extension DescribePrompt {
    /// One screenshot of a batch.
    public struct BatchItem: Sendable {
        /// The capture id; what the answer's `id` must say.
        public let id: String
        public let resolved: ResolvedApp?
        public let input: Input
        /// The picture, sent only when `input.mode` sends one.
        public let imageJPEG: Data?
        public let imageFile: URL?

        public init(id: String, resolved: ResolvedApp?, input: Input, imageJPEG: Data?, imageFile: URL? = nil) {
            self.id = id
            self.resolved = resolved
            self.input = input
            self.imageJPEG = imageJPEG
            self.imageFile = imageFile
        }

        var sendsImage: Bool { input.mode.sendsImage && imageJPEG != nil }
    }

    /// Added to the system instruction for a batch only, so a single screenshot's stays d3's.
    public static let batchInstruction = """
        You may receive several screenshots at once, oldest first, each with its own id. \
        Describe each one on its own, in its own entry with its own id; the earlier ones are \
        context for the later ones, so say what is new rather than repeating them.
        """

    /// `Screenshot 3 of 7, 14:32:10`: how the prompt heads a screenshot, and the label its
    /// picture carries.
    public static func batchLabel(index: Int, count: Int, at date: Date, timeZone: TimeZone) -> String {
        "Screenshot \(index + 1) of \(count), \(clockSeconds(date, timeZone: timeZone))"
    }

    public static func batchSystemInstruction(language: String) -> String {
        ReportLanguage.applied(to: systemInstruction + " " + batchInstruction, code: language)
    }

    public static func batchRequest(
        items: [BatchItem],
        taxonomy: TaxonomyStore,
        timeZone: TimeZone = .current,
        language: String = ReportLanguage.english,
        projects: [ProjectEntry]? = nil,
        repairNote: String? = nil
    ) -> DescribeRequest {
        let listed = projects ?? promptProjects(taxonomy.projects)
        var images: [DescribeImage] = []
        for (index, item) in items.enumerated() where item.sendsImage {
            guard let jpeg = item.imageJPEG else { continue }
            images.append(DescribeImage(
                frameId: item.id,
                label: batchLabel(index: index, count: items.count, at: item.input.at, timeZone: timeZone),
                jpeg: jpeg,
                file: item.imageFile
            ))
        }
        return DescribeRequest(
            images: images,
            systemInstruction: batchSystemInstruction(language: language),
            userPrompt: batchUserPrompt(
                items: items, taxonomy: taxonomy, timeZone: timeZone, projects: listed, repairNote: repairNote
            ),
            schema: batchSchema(items: items, taxonomy: taxonomy.current, projects: listed),
            maxOutputTokens: maxOutputTokens * max(1, items.count)
        )
    }

    public static func batchUserPrompt(
        items: [BatchItem],
        taxonomy: TaxonomyStore,
        timeZone: TimeZone = .current,
        projects: [ProjectEntry]? = nil,
        repairNote: String? = nil
    ) -> String {
        let count = items.count
        let imageCount = items.filter(\.sendsImage).count
        var lines = [
            "These are \(count) screenshots from one stretch of work, oldest first. "
                + "Summarize each one on its own.",
        ]
        if let first = items.first, let context = contextBlock(first.input.context, timeZone: timeZone) {
            lines.append("Context before screenshot 1:")
            lines.append(context)
        }
        lines.append("Known tasks, by app:")
        lines.append(taxonomy.promptFragment(forApps: items.map(\.resolved)))
        let listed = projects ?? promptProjects(taxonomy.projects)
        if let block = knownProjects(listed) { lines.append(block) }

        var imageNumber = 0
        for (index, item) in items.enumerated() {
            let input = item.input
            lines.append("")
            lines.append(batchLabel(index: index, count: count, at: input.at, timeZone: timeZone))
            lines.append("id: \(item.id)")
            lines.append("Time: \(timestamp(input.at, timeZone: timeZone))")
            lines.append("App: \(batchAppLine(resolved: item.resolved, input: input))")
            lines.append("App key: \(item.resolved?.appKey ?? "not recognized")")
            lines.append("Window title: \(input.windowTitle?.nonEmpty ?? "unknown")")
            lines.append("URL: \(input.url?.nonEmpty ?? "n/a")")
            lines.append("In meeting (per calendar/detector): \(meetingLine(input))")
            if let text = windowTextBlock(input) { lines.append(text) }
            if item.sendsImage {
                imageNumber += 1
                lines.append("Image: attached, image \(imageNumber) of \(imageCount).")
            } else {
                lines.append("Image: none; describe it from the window text.")
            }
        }
        lines.append("")
        lines.append(
            "Answer with one entry in \"screenshots\" for each id above, in the same order, each "
                + "describing only its own screenshot. Prefer a universal task key over proposing a new one."
        )
        if let repairNote { lines.append(repairNote) }
        return lines.joined(separator: "\n")
    }

    /// `{ "screenshots": [ … ] }`, each entry one screenshot's fields plus its `id`. The enums
    /// are the union over the batch, since a schema cannot tie an id to its own app; the worker
    /// checks each entry's `app_key` against its own screenshot after decoding.
    public static func batchSchema(items: [BatchItem], taxonomy: Taxonomy, projects: [ProjectEntry]? = nil) -> JSONValue {
        var appKeys: [String] = []
        var taskKeys: [String] = []
        for item in items {
            if let resolved = item.resolved {
                appKeys.append(resolved.appKey)
                taskKeys += resolved.tasks.map(\.key)
            } else {
                appKeys += taxonomy.allAppKeys
            }
        }
        appKeys.append("other")
        taskKeys += taxonomy.universalTaskKeys

        var properties = frameProperties(
            appKeys: appKeys,
            taskKeys: taskKeys,
            projectKeys: (projects ?? promptProjects(taxonomy.projectList)).map(\.key)
        )
        properties["id"] = .object([
            "type": .string("string"),
            "enum": .array(uniqued(items.map(\.id)).map(JSONValue.string)),
            "description": .string("The id of the screenshot this entry describes."),
        ])
        let entry: JSONValue = .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object(properties),
            "required": .array((["id"] + frameRequired).map(JSONValue.string)),
        ])
        return .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "screenshots": .object([
                    "type": .string("array"),
                    "items": entry,
                ]),
            ]),
            "required": .array([.string("screenshots")]),
        ])
    }

    /// The app keys one screenshot may be labelled with: its own app's and `other`, or every
    /// app key when the taxonomy did not recognize it. The same set `schema` allows a single
    /// screenshot, which a batch's union cannot enforce on its own.
    public static func allowedAppKeys(resolved: ResolvedApp?, taxonomy: Taxonomy) -> Set<String> {
        guard let resolved else { return Set(taxonomy.allAppKeys + ["other"]) }
        return [resolved.appKey, "other"]
    }

    /// One batch answer, split per screenshot. An entry whose id is not in the batch, repeats an
    /// id, or does not decode is left out; the worker sends those screenshots again on their own.
    /// Throws `DecodingError` when the answer is not the batch shape at all, or not one entry
    /// in it is usable, which is what the one repair attempt is for.
    public static func decodeBatch(_ json: String, ids: [String]) throws -> [String: (frame: FrameDescription, raw: String)] {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not JSON: \(error)"))
        }
        guard let entries = value["screenshots"]?.arrayValue else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "no screenshots array"))
        }
        let known = Set(ids)
        var counts: [String: Int] = [:]
        for entry in entries {
            if let id = entry["id"]?.stringValue { counts[id, default: 0] += 1 }
        }
        var decoded: [String: (frame: FrameDescription, raw: String)] = [:]
        for entry in entries {
            guard let id = entry["id"]?.stringValue, known.contains(id), counts[id] == 1 else { continue }
            let raw = compactJSON(entry)
            guard let frame = try? FrameDescription.decoder().decode(FrameDescription.self, from: Data(raw.utf8)) else {
                continue
            }
            decoded[id] = (frame, raw)
        }
        guard !decoded.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "no usable entry"))
        }
        return decoded
    }

    static func compactJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func batchAppLine(resolved: ResolvedApp?, input: Input) -> String {
        let name = input.appName?.nonEmpty ?? resolved?.name ?? "unknown"
        guard let bundleID = input.bundleID?.nonEmpty else { return name }
        return "\(name) (\(bundleID))"
    }

    /// `14:32:10`: a batch can hold two screenshots from the same minute.
    static func clockSeconds(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
