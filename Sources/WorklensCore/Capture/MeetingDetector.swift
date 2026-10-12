import Foundation

/// "Are you in a meeting right now?", answered from foreground metadata *and* from what the
/// context sources synced (#19).
///
/// Two things depend on the answer. The capture scheduler drops to
/// `MEETING_CAPTURE_INTERVAL_SECONDS`, because a meeting is the one time a 60 s screenshot buys
/// nothing — the screen is a static grid of faces. And the describer is told which meeting it
/// is, so the timeline can say "Portfolio review" instead of "a video call with four people".
@MainActor
public final class MeetingDetector: ObservableObject {
    @Published public private(set) var isInMeeting: Bool = false
    /// The calendar or Granola event covering right now, when one does. Nil during a meeting
    /// only the foreground app knows about.
    @Published public private(set) var currentMeeting: ContextEvent?

    /// People join a minute early and calls run a minute over, so the calendar window is opened
    /// by two minutes on each side before it is believed.
    public nonisolated static let calendarTolerance: TimeInterval = 120

    private let now: @Sendable () -> Date
    /// The meetings around now, pushed in by `ContextSyncScheduler` after every sync round.
    private var events: [ContextEvent] = []
    private var lastContext: ForegroundContext?

    public init(isInMeeting: Bool = false, now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
        self.isInMeeting = isInMeeting
    }

    public func update(context: ForegroundContext) {
        lastContext = context
        recompute()
    }

    /// Replaces the known meeting windows. Cheap and idempotent — the scheduler calls it with
    /// the next half-day of meetings after each sync.
    public func setContextEvents(_ events: [ContextEvent]) {
        self.events = events.filter(\.isMeeting).sorted { $0.startAt < $1.startAt }
        recompute()
    }

    /// Re-answers the question at the current instant, without new metadata. The capture
    /// scheduler gets this for free because it calls `update(context:)` every tick; anything
    /// polling `isInMeeting` on its own should call this first.
    public func recompute() {
        let at = now()
        let event = MeetingDetector.meeting(covering: at, in: events)
        let foreground = lastContext.map {
            MeetingDetector.detects(bundleID: $0.bundleID, urlHost: $0.urlHost, windowTitle: $0.windowTitle)
        } ?? false

        // Precedence: a real calendar entry names the meeting, so it wins when both agree. The
        // foreground rule can still turn the answer on by itself — an unscheduled huddle is
        // still a meeting.
        let detected = event != nil || foreground
        if detected != isInMeeting { isInMeeting = detected }
        if event?.id != currentMeeting?.id { currentMeeting = event }
    }

    // MARK: Rules (pure)

    public nonisolated static let meetingBundleIDs: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.apple.FaceTime",
        "com.cisco.webexmeetingsapp",
    ]

    public nonisolated static let meetingHosts: Set<String> = [
        "meet.google.com",
        "zoom.us",
        "teams.microsoft.com",
    ]

    nonisolated static let slackBundleID = "com.tinyspeck.slackmacgap"

    /// What a browser window is called during a call, for the frames that have no host (#64).
    ///
    /// Prefixes, not substrings: the page title comes first in the window title — the browser's
    /// own name is cut off the end by `BrowserRegistry.strippedTitle` — so anchoring is what
    /// keeps "Meet the team - Google Docs" and "Notes on Microsoft Teams rollout" out.
    public nonisolated static let meetingTitlePrefixes: [String] = [
        "Meet - ",          // Google Meet: "Meet - abc-defg-hij"
        "Zoom Meeting",     // the Zoom web client
        "Microsoft Teams",  // Teams in a browser
    ]

    /// True for a meeting app, a meeting URL (including subdomains such as `acme.zoom.us`), a
    /// Slack window whose title says Huddle, or — when there is no host to go on — a browser
    /// window whose title is one a call gives it.
    ///
    /// The title rule only runs for a browser with `urlHost == nil`, which is exactly the case
    /// #64 is about: a day where neither the accessibility header nor the AppleScript probe
    /// answered, so the whole meeting went undetected and was captured at the full 60 s rate. A
    /// host, when there is one, is the better signal and still decides first.
    public nonisolated static func detects(bundleID: String?, urlHost: String?, windowTitle: String?) -> Bool {
        if let bundleID, meetingBundleIDs.contains(bundleID) { return true }

        if let host = urlHost?.lowercased(),
           meetingHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
            return true
        }

        if bundleID == slackBundleID,
           windowTitle?.range(of: "huddle", options: .caseInsensitive) != nil {
            return true
        }

        if urlHost == nil, BrowserRegistry.isBrowser(bundleID),
           let title = windowTitle?.trimmingCharacters(in: .whitespaces), !title.isEmpty,
           meetingTitlePrefixes.contains(where: {
               title.range(of: $0, options: [.caseInsensitive, .anchored]) != nil
           }) {
            return true
        }
        return false
    }

    /// The event covering `instant`, tolerance included. When several overlap — a call that runs
    /// into the next one — the one that started most recently is the one you are actually in.
    public nonisolated static func meeting(
        covering instant: Date,
        in events: [ContextEvent],
        tolerance: TimeInterval = calendarTolerance
    ) -> ContextEvent? {
        events
            .filter { $0.isMeeting && $0.covers(instant, tolerance: tolerance) }
            .max { $0.startAt < $1.startAt }
    }
}
