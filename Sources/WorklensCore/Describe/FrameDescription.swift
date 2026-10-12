import Foundation

/// The JSON the vision model must return for one frame. Decoded with
/// `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase`, so `app_key` → `appKey`.
///
/// d5 (#315) dropped `people` and `confidence` from the schema: nothing read either one. An older
/// answer that still carries them decodes fine, because unknown keys are ignored.
public struct FrameDescription: Codable, Sendable, Equatable {
    /// A key from the taxonomy, or `other`.
    public var appKey: String
    /// A task key legal for `appKey`, or a universal task.
    public var taskKey: String
    /// One or two factual sentences, present tense.
    public var summary: String
    /// The document, page, file or thread on screen, if its name is visible.
    public var document: String?
    /// The company, deal or project the content is about, when it is evident.
    public var projectHint: String?
    /// The catalog entry the frame is about, picked from the keys the prompt listed (#315). Nil
    /// when none fits, when the catalog is empty, and on every answer older than d5.
    public var projectKey: String?
    public var isMeeting: Bool
    /// Passwords, banking, personal chats, medical, HR, private browsing.
    public var isSensitive: Bool

    public init(
        appKey: String,
        taskKey: String,
        summary: String,
        document: String? = nil,
        projectHint: String? = nil,
        projectKey: String? = nil,
        isMeeting: Bool = false,
        isSensitive: Bool = false
    ) {
        self.appKey = appKey
        self.taskKey = taskKey
        self.summary = summary
        self.document = document
        self.projectHint = projectHint
        self.projectKey = projectKey
        self.isMeeting = isMeeting
        self.isSensitive = isSensitive
    }

    /// Tolerates every optional field being absent, which some models do even when the schema
    /// marks it required. A `null` `project_key` is how the model says no listed project fits.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appKey = try container.decode(String.self, forKey: .appKey)
        taskKey = try container.decode(String.self, forKey: .taskKey)
        summary = NoEmDash.replaced(try container.decode(String.self, forKey: .summary))
        document = try container.decodeIfPresent(String.self, forKey: .document)
        projectHint = try container.decodeIfPresent(String.self, forKey: .projectHint)
        projectKey = try container.decodeIfPresent(String.self, forKey: .projectKey)?.nonEmpty
        isMeeting = try container.decodeIfPresent(Bool.self, forKey: .isMeeting) ?? false
        isSensitive = try container.decodeIfPresent(Bool.self, forKey: .isSensitive) ?? false
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    /// The `details_json` column: everything the flat `descriptions` columns have no room for.
    public var detailsJSON: String? { detailsJSON(redactions: [:]) }

    /// The same column with what `TextRedactor` took out of the title and the URL before the
    /// prompt was built (#49), under `redactions`, so a day's redactions can be counted from
    /// the stored rows. Empty counts add nothing, so a clean frame's JSON is unchanged.
    public func detailsJSON(redactions: [String: Int]) -> String? {
        var details: [String: JSONValue] = [:]
        if let document { details["document"] = .string(document) }
        if let projectHint { details["project_hint"] = .string(projectHint) }
        if let projectKey { details["project_key"] = .string(projectKey) }
        if !redactions.isEmpty {
            details["redactions"] = .object(redactions.mapValues { .number(Double($0)) })
        }
        guard !details.isEmpty else { return nil }
        let data = try? JSONEncoder().encode(JSONValue.object(details))
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }
}
