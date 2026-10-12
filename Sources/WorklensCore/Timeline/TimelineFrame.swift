import Foundation

/// One capture as the timeline sees it: a moment, what it was, and the few flags that decide
/// whether it becomes its own block. Flat and value-typed so `BlockBuilder` can stay a pure
/// function with no database in sight.
public struct TimelineFrame: Sendable, Equatable {
    public let captureId: String
    public let at: Date
    /// Nil while the frame is still pending or has failed — such frames are simply not drawn.
    public let appKey: String?
    public let taskKey: String?
    public let title: String?
    public let summary: String?
    /// The document, page, file or thread the describer named, from `descriptions.details_json`
    /// (#69). Parsed when the day's frames load, so the renderer never touches JSON.
    public let document: String?
    /// The company, deal or project the describer named, from the same column.
    public let projectHint: String?
    /// The catalog key the describer picked (#315, d5), when it picked one. A key the catalog no
    /// longer has is left for `ProjectNames` to drop.
    public let projectKey: String?
    public let bundleID: String?
    /// The name macOS reports for the frontmost app. Kept because an app whose window title is
    /// its own name ("Claude", "Granola") says nothing, and that is what the check compares to.
    public let appName: String?
    public let url: String?
    public let isIdle: Bool
    public let isRedacted: Bool
    public let isMeeting: Bool
    /// Copied from an earlier frame: it costs nothing and it must not be quoted twice.
    public let isInherited: Bool
    public let isSensitive: Bool
    /// How long this frame stands for: the scheduler's interval when it was taken, from
    /// `captures.interval_seconds`. Nil on rows written before that column, which fall back to
    /// the configured interval `BlockBuilder` is handed.
    public let intervalSeconds: TimeInterval?

    public init(
        captureId: String,
        at: Date,
        appKey: String? = nil,
        taskKey: String? = nil,
        title: String? = nil,
        summary: String? = nil,
        document: String? = nil,
        projectHint: String? = nil,
        projectKey: String? = nil,
        bundleID: String? = nil,
        appName: String? = nil,
        url: String? = nil,
        isIdle: Bool = false,
        isRedacted: Bool = false,
        isMeeting: Bool = false,
        isInherited: Bool = false,
        isSensitive: Bool = false,
        intervalSeconds: TimeInterval? = nil
    ) {
        self.captureId = captureId
        self.at = at
        self.appKey = appKey
        self.taskKey = taskKey
        self.title = title
        self.summary = summary
        self.document = document
        self.projectHint = projectHint
        self.projectKey = projectKey
        self.bundleID = bundleID
        self.appName = appName
        self.url = url
        self.isIdle = isIdle
        self.isRedacted = isRedacted
        self.isMeeting = isMeeting
        self.isInherited = isInherited
        self.isSensitive = isSensitive
        self.intervalSeconds = intervalSeconds
    }
}

public extension TimelineFrame {
    /// The app/task pair this frame contributes to a block, or nil when the frame has no
    /// description yet and nothing else to say.
    ///
    /// Order matters: away from the keyboard outranks a meeting, and a blocked app outranks
    /// both — privacy is not negotiated with bookkeeping.
    var blockKey: (appKey: String, taskKey: String)? {
        if isIdle { return (BlockBuilder.idleKey, BlockBuilder.idleKey) }
        if isRedacted { return (appKey ?? BlockBuilder.unknownAppKey, BlockBuilder.redactedTaskKey) }
        if isMeeting { return (appKey ?? BlockBuilder.unknownAppKey, BlockBuilder.meetingTaskKey) }
        guard let appKey, let taskKey else { return nil }
        return (appKey, taskKey)
    }
}

public extension TimelineFrame {
    /// The fields the timeline reads out of `descriptions.details_json` (#69). Parsed once,
    /// where a day's frames are loaded, rather than in the renderer. `projectKey` is absent on
    /// every row written before d5 (#315), which then reads exactly as it did.
    struct Details: Sendable, Equatable {
        public var document: String?
        public var projectHint: String?
        public var projectKey: String?

        public init(document: String? = nil, projectHint: String? = nil, projectKey: String? = nil) {
            self.document = document
            self.projectHint = projectHint
            self.projectKey = projectKey
        }
    }

    /// Tolerant on purpose: an absent, empty or malformed column simply carries no document.
    static func details(json: String?) -> Details {
        guard let data = json?.nonEmpty?.data(using: .utf8) else { return Details() }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let payload = try? decoder.decode(DetailsPayload.self, from: data) else {
            return Details()
        }
        return Details(
            document: payload.document?.nonEmpty,
            projectHint: payload.projectHint?.nonEmpty,
            projectKey: payload.projectKey?.nonEmpty
        )
    }
}

/// Only the keys the timeline needs; `people` and `redactions` are none of its business.
private struct DetailsPayload: Decodable {
    var document: String?
    var projectHint: String?
    var projectKey: String?
}
