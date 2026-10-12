import Foundation

/// The offline provider: everything the pipeline needs to run end to end with no API keys, no
/// network and no money (#121).
///
/// It exists so a stranger can judge the product before creating a paid account, and so a
/// contributor can work on the describe stage without billing. It is never selected by
/// configuration: `--fake` on `describe-pending` is the only way in, which is what keeps a
/// made-up summary out of a real data directory by construction.
///
/// Every string it produces carries `FakeProvider.marker`, and everything it writes to the ledger
/// is zero — 0 tokens, $0.00 — because nothing was sent anywhere.
public enum FakeProvider {
    /// What goes in `llm_calls.provider` and `descriptions.provider`.
    public static let name = "fake"
    /// What goes in the `model` columns. Not a model that exists, which is the point.
    public static let model = "fake-offline"

    /// The one phrase that makes fake output impossible to mistake for real output. It appears in
    /// every frame summary, and so throughout the timeline built from them.
    public static let marker = "sample, not a real summary"

    /// The same phrase where a sentence starts, which is most places it is read.
    public static let markerSentence = "Sample, not a real summary."

    /// FNV-1a over the prompt. Deterministic across processes and machines, which
    /// `String.hashValue` is not: Swift seeds that per process, so a fake seeded from it would
    /// answer differently on every run.
    public static func seed(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x1000_0193
        }
        return hash
    }

    /// The element `seed` picks out of `options`, or nil when there are none.
    static func pick<T>(_ options: [T], seed: UInt64, salt: UInt64 = 0) -> T? {
        guard !options.isEmpty else { return nil }
        return options[Int((seed &+ salt &* 0x9e37_79b9) % UInt64(options.count))]
    }

    /// The `"…"` values of a JSON Schema `enum` at `property`, in schema order.
    static func enumValues(_ schema: JSONValue, property: String) -> [String] {
        schema["properties"]?[property]?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    /// The value of a `Key: value` line in a prompt, trimmed. Nil when the line is absent or says
    /// `unknown`.
    static func promptField(_ prompt: String, key: String) -> String? {
        for line in prompt.split(separator: "\n") where line.hasPrefix("\(key): ") {
            let value = line.dropFirst(key.count + 2).trimmingCharacters(in: .whitespaces)
            return (value.isEmpty || value == "unknown" || value == "n/a") ? nil : value
        }
        return nil
    }
}

// MARK: - Describing

/// A `VisionDescriber` that answers from the prompt alone: no image is looked at, nothing leaves
/// the machine, and the same frame always produces the same sentence.
///
/// The labels come out of the request's own JSON Schema, so a fake description is always legal for
/// the app it belongs to — `DescribeWorker` clamps an illegal key to `other`, and a demo whose
/// every frame said `other` would show nothing worth looking at.
public struct FakeDescriber: VisionDescriber {
    public init() {}

    public var provider: String { FakeProvider.name }

    public func describe(_ request: DescribeRequest) async throws -> DescribeResponse {
        let seed = FakeProvider.seed(request.userPrompt)
        let appKeys = FakeProvider.enumValues(request.schema, property: "app_key")
        let taskKeys = FakeProvider.enumValues(request.schema, property: "task_key")
        // The first app key is the one the taxonomy resolved for this frame; `other` is the
        // fallback the schema always appends.
        let appKey = appKeys.first ?? "other"
        // The first one, not a hashed pick: the schema lists the app's own tasks before the
        // universal fallbacks, so the first is the one that app is mostly used for. A pick would
        // label a stretch of Slack `switching`, which cuts the run into a block per frame and
        // makes the demo's day look like nothing a person did.
        let taskKey = taskKeys.first ?? "other"

        let frame = FrameDescription(
            appKey: appKey,
            taskKey: taskKey,
            summary: summary(request: request, taskKey: taskKey, seed: seed),
            document: FakeProvider.promptField(request.userPrompt, key: "Window title"),
            // Left empty on purpose: a project name is the one field the catalog learns from, and
            // an invented one would end up in a real `taxonomy.json` if a fake run ever met one.
            projectHint: nil,
            isMeeting: false,
            isSensitive: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(EncodableFrame(frame)), as: UTF8.self)
        return DescribeResponse(
            json: json, usage: .zero, costUSD: 0, latencyMs: 0, model: FakeProvider.model
        )
    }

    /// Present tense, opens with a verb, no second person — the same rules the real prompt asks
    /// for — with the marker in front so it is unmistakable wherever the sentence is shown.
    private func summary(request: DescribeRequest, taskKey: String, seed: UInt64) -> String {
        // "Google Chrome (com.google.Chrome)" → "Google Chrome": the bundle id is in the
        // prompt for the model's benefit, not for a sentence a person reads in the timeline.
        let appLine = FakeProvider.promptField(request.userPrompt, key: "App") ?? "an app"
        let app = appLine.split(separator: " (").first.map(String.init) ?? appLine
        let task = taskKey.replacingOccurrences(of: "_", with: " ")
        let verb =
            FakeProvider.pick(
                ["Continues", "Works on", "Picks up", "Stays with"], seed: seed, salt: 7
            ) ?? "Works on"
        return "\(FakeProvider.markerSentence) \(verb) \(task) in \(app); this sentence was "
            + "made up offline and no model saw a screen."
    }

    /// `FrameDescription` decodes snake_case but encodes its own property names, and the worker
    /// re-decodes whatever a describer returns. Encoding the snake_case shape keeps the fake on
    /// exactly the round trip a real answer takes.
    private struct EncodableFrame: Encodable {
        let appKey: String
        let taskKey: String
        let summary: String
        let document: String?
        let isMeeting: Bool
        let isSensitive: Bool

        init(_ frame: FrameDescription) {
            appKey = frame.appKey
            taskKey = frame.taskKey
            summary = frame.summary
            document = frame.document
            isMeeting = frame.isMeeting
            isSensitive = frame.isSensitive
        }

        enum CodingKeys: String, CodingKey {
            case appKey = "app_key"
            case taskKey = "task_key"
            case summary, document
            case isMeeting = "is_meeting"
            case isSensitive = "is_sensitive"
        }
    }
}
