import Foundation
import GRDB

/// Row identifiers are lowercase UUID strings everywhere in the schema.
public enum Identifiers {
    public static func new() -> String { UUID().uuidString.lowercased() }
}

/// Why a frame was recorded but not sent to the vision model.
public enum SkipReason: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case unchanged, idle, locked, budget
    /// Blocked, with no record of by which list. Only rows written before #16 carry this.
    case blocked
    case blockedBundle = "blocked:bundle"
    case blockedTitle = "blocked:title"
    case blockedHost = "blocked:host"
    /// `BLOCKED_URL_HOSTS` is set and a browser was in front whose address could not be read, so
    /// there was no telling whether the page was a blocked one. Recorded as blocked: the host
    /// blocklist fails closed rather than letting an unknown page through (security finding #4).
    case blockedHostUnknown = "blocked:host_unknown"
    /// `CAPTURE_SOURCE=accessibility` and the focused window exposed nothing to walk (#54).
    /// There is no picture to fall back to in that mode, so the frame is recorded and not
    /// described. The timeline treats it the way it treats an unchanged frame: it carries no
    /// label of its own, so the block around it continues.
    case noText = "no_text"
    /// The Mac was asleep (#313). Rows before it say `locked` for sleep too; they are not
    /// rewritten. Recorded idle, so everything downstream treats it the way it treats `locked`.
    case asleep

    /// True for `blocked` and every refinement of it — what a caller that only cares whether the
    /// frame was blocked should ask, so a new list does not need a new comparison everywhere.
    public var isBlocked: Bool {
        switch self {
        case .blocked, .blockedBundle, .blockedTitle, .blockedHost, .blockedHostUnknown: return true
        case .unchanged, .idle, .locked, .asleep, .budget, .noText: return false
        }
    }
}

/// Which artifacts a frame carries. Nullable on the row: every capture written before #53 was
/// pixels only, and saying so explicitly would be inventing history.
///
/// A plain three-case enum rather than a set, because that is what `CAPTURE_SOURCE` will select
/// between in #54: `screenshot` is a JPEG and nothing else, `both` is a JPEG plus a stored
/// accessibility outline, and `accessibility` — written from #54 on — is an outline with no
/// picture at all.
public enum CaptureSource: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case screenshot, both, accessibility
}

/// Where a frame's window title and browser URL came from, as stored on the row (#55). Nullable
/// for every row written before it, and for skip and blocked rows, which carry neither field.
extension ForegroundContext.Source: DatabaseValueConvertible {}

/// Where a frame is in the describe pipeline.
public enum DescribeStatus: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case pending, described, inherited, skipped, failed
}

/// One screenshot moment: the pixels (maybe) plus the OS metadata around them.
public struct Capture: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "captures"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: String
    public var capturedAt: Date
    public var displayId: Int?
    /// Relative to `DATA_DIR`. Nil when the frame was never saved or has since been deleted.
    public var imagePath: String?
    public var width: Int?
    public var height: Int?
    /// 16 hex characters — the 64-bit difference hash of the frame.
    public var dhash: String?
    /// Change against the previous fingerprint, 0...1. Nil for the first frame.
    public var changeScore: Double?
    public var appBundleId: String?
    public var appName: String?
    public var windowTitle: String?
    public var browserUrl: String?
    public var urlHost: String?
    public var contextSignature: String?
    /// Which artifacts this frame carries. Nil for every row written before #53.
    public var captureSource: CaptureSource?
    /// Which reader supplied `windowTitle` and `browserUrl` (#55). Nil on rows that carry neither
    /// — skips, blocked frames — and on every row written before that issue.
    public var titleSource: ForegroundContext.Source?
    public var urlSource: ForegroundContext.Source?
    public var isIdle: Bool
    public var isRedacted: Bool
    public var isMeeting: Bool
    /// The scheduler's interval when this frame was taken, after the battery and meeting
    /// stretches and before jitter. Nil on every row written before the `capture-interval`
    /// migration, and on idle/lock rows, which stand for a period rather than a tick.
    public var intervalSeconds: Int?
    public var skipReason: SkipReason?
    public var describeStatus: DescribeStatus
    public var describeAttempts: Int
    public var createdAt: Date

    public init(
        id: String = Identifiers.new(),
        capturedAt: Date,
        displayId: Int? = nil,
        imagePath: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        dhash: String? = nil,
        changeScore: Double? = nil,
        appBundleId: String? = nil,
        appName: String? = nil,
        windowTitle: String? = nil,
        browserUrl: String? = nil,
        urlHost: String? = nil,
        contextSignature: String? = nil,
        captureSource: CaptureSource? = nil,
        titleSource: ForegroundContext.Source? = nil,
        urlSource: ForegroundContext.Source? = nil,
        isIdle: Bool = false,
        isRedacted: Bool = false,
        isMeeting: Bool = false,
        intervalSeconds: Int? = nil,
        skipReason: SkipReason? = nil,
        describeStatus: DescribeStatus = .pending,
        describeAttempts: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.displayId = displayId
        self.imagePath = imagePath
        self.width = width
        self.height = height
        self.dhash = dhash
        self.changeScore = changeScore
        self.appBundleId = appBundleId
        self.appName = appName
        self.windowTitle = windowTitle
        self.browserUrl = browserUrl
        self.urlHost = urlHost
        self.contextSignature = contextSignature
        self.captureSource = captureSource
        self.titleSource = titleSource
        self.urlSource = urlSource
        self.isIdle = isIdle
        self.isRedacted = isRedacted
        self.isMeeting = isMeeting
        self.intervalSeconds = intervalSeconds
        self.skipReason = skipReason
        self.describeStatus = describeStatus
        self.describeAttempts = describeAttempts
        self.createdAt = createdAt
    }
}
