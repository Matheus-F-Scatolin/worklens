import AppKit
import Foundation
import WorklensCore

/// The ways of summarizing, as the welcome window and Settings → Connections show them: the
/// status checks, Connect, Disconnect and the order arrows, and the notices that come from what
/// the chain has learned.
///
/// Security, absolute: nothing here runs `claude auth login` or `codex login`, reads a keychain
/// item or a credential file, or signs a command out. The status check is `claude auth status
/// --json` and `codex login status`; Disconnect only takes the name out of `SUMMARY_PROVIDERS`.
extension AppModel {
    var summaryProvidersKey: String { "SUMMARY_PROVIDERS" }

    /// The three cards, from the configuration and the last status checks.
    var summaryConnections: [SummaryConnection] {
        SummaryConnection.all(config: config, statuses: subscriptionStatuses)
    }

    /// Settings → Connections' rows: the listed providers in the order they are tried, then the
    /// others in the default order.
    var summaryRowOrder: [SummaryProvider] {
        let listed = SummaryProviders.listed(config)
        return listed + SummaryProviders.defaultOrder.filter { !listed.contains($0) }
    }

    /// What the chain says went wrong with one provider, for its row.
    func summaryRowProblem(_ provider: SummaryProvider) -> (text: String, help: WorklensCore.HelpLink?)? {
        SummaryNotices.rowProblem(
            provider, order: SummaryProviders.effective(config), skips: summaryChain?.skipped() ?? [],
            timeZone: .autoupdatingCurrent, locale: .autoupdatingCurrent
        )
    }

    // MARK: Status checks

    /// Asks both commands whether they are signed in, unless a check is already running. A
    /// command found signed in with a plan is tried first again on the next screenshot, so
    /// signing back in moves the summaries back without waiting out the chain's quarter hour.
    func refreshSubscriptionStatuses() {
        guard subscriptionStatusTask == nil else { return }
        let dataDir = config.dataDir
        subscriptionStatusCheckedAt = Date()
        subscriptionStatusTask = Task { [weak self] in
            let statuses = await Self.checkSubscriptions(dataDir: dataDir)
            guard let self else { return }
            self.subscriptionStatuses = statuses
            self.subscriptionStatusTask = nil
            let now = Date()
            for (tool, status) in statuses where status.isUsable(now: now) {
                if let provider = SummaryProvider(rawValue: tool.rawValue) {
                    self.summaryChain?.forgetSkip(provider)
                }
            }
            if let db = self.db { self.refreshSummaryNotices(db: db) }
        }
    }

    /// Waits for the check that is running, or runs one, and returns what it found.
    func checkSubscriptionsNow() async -> [SubscriptionTool: SubscriptionStatus] {
        if let running = subscriptionStatusTask {
            await running.value
            return subscriptionStatuses
        }
        refreshSubscriptionStatuses()
        await subscriptionStatusTask?.value
        return subscriptionStatuses
    }

    private nonisolated static func checkSubscriptions(
        dataDir: URL
    ) async -> [SubscriptionTool: SubscriptionStatus] {
        let workspace = SubscriptionWorkspace(dataDir: dataDir)
        do {
            try workspace.prepare()
        } catch {
            Log.describe.warn("could not prepare the folder the sign-in check runs in: \(error)")
        }
        let checker = SubscriptionStatusChecker(
            cli: SubscriptionCLIRunner(), workingDirectory: workspace.emptyDirectory
        )
        async let claude = checker.status(.claude)
        async let codex = checker.status(.codex)
        let found = await [claude, codex]
        // Only the state, never the command's own output.
        for status in found {
            Log.describe.debug("\(status.tool.rawValue) status: \(String(describing: status.login))")
        }
        return Dictionary(uniqueKeysWithValues: found.map { ($0.tool, $0) })
    }

    // MARK: Connect, Disconnect, order

    /// Checks the command again and, only if it is signed in with a plan, adds it to the list.
    /// Returns whether it was connected. Gemini connects by saving a key (`setCredential`).
    @discardableResult
    func connectSummaryProvider(_ provider: SummaryProvider) async -> Bool {
        guard let tool = provider.tool else {
            // Gemini: a key that is saved but not in the list.
            guard !(config.geminiAPIKey ?? "").isEmpty else { return false }
            return saveSetting(
                summaryProvidersKey, SummaryProviders.value(SummaryProviders.connecting(.gemini, config: config)),
                as: L10n.format("%@ connected", SummaryConnection.name(provider))
            )
        }
        let statuses = await checkSubscriptionsNow()
        guard let status = statuses[tool], status.isUsable() else { return false }
        let list = SummaryProviders.connecting(provider, config: config)
        summaryChain?.forgetSkip(provider)
        return saveSetting(
            summaryProvidersKey, SummaryProviders.value(list),
            as: L10n.format("%@ connected", SummaryConnection.name(provider))
        )
    }

    /// Takes the provider out of the list. The command stays signed in; for Gemini the saved key
    /// is forgotten too, as Disconnect always did.
    func disconnectSummaryProvider(_ provider: SummaryProvider) {
        if provider == .gemini {
            do {
                try clearCredential(.gemini)
                settingsToast(String(localized: "Gemini disconnected", comment: "Toast"))
            } catch {
                settingsFailures[summaryProvidersKey] = "\(error)"
            }
            return
        }
        let list = SummaryProviders.disconnecting(provider, config: config)
        saveSetting(
            summaryProvidersKey, SummaryProviders.value(list),
            as: L10n.format("%@ disconnected", SummaryConnection.name(provider))
        )
    }

    /// One place earlier (`-1`) or later (`1`) in the order Worklens tries.
    func moveSummaryProvider(_ provider: SummaryProvider, by offset: Int) {
        let list = SummaryProviders.moving(provider, by: offset, config: config)
        guard list != SummaryProviders.listed(config) else { return }
        saveSetting(
            summaryProvidersKey, SummaryProviders.value(list),
            as: String(localized: "Summary order", comment: "Toast")
        )
    }

    // MARK: Terminal

    /// Puts a sign-in command on the clipboard. Worklens never runs it.
    func copySignInCommand(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    /// Opens Terminal, empty: the person pastes the command and signs in there themselves.
    func openTerminal() {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.openApplication(at: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Notices

    /// Re-derives the notices about summarizing on every refresh, so none outlives its cause:
    /// a sign-in that stopped working, a plan at its limit, and a pile of screenshots that have
    /// been waiting more than an hour. The last only once a subscription is in the order, so a
    /// Gemini-only install keeps exactly the notices it had.
    func refreshSummaryNotices(db: Database) {
        let now = Date()
        let queries = DescribeQueries(db)
        lastSummaryByProvider = (try? queries.lastSummaryByProvider()) ?? [:]
        let order = SummaryProviders.effective(config)
        let skips = summaryChain?.skipped() ?? []
        let statuses = subscriptionStatuses
        let signedOut = SummaryAlerts.signedOutTools(order: order, skips: skips, statuses: statuses, now: now)
        let summarizing = SummaryAlerts.summarizing(order: order, skips: skips, signedOut: signedOut, now: now)
        var open = SummaryNotices.derive(
            order: order, skips: skips, now: now,
            timeZone: .autoupdatingCurrent, locale: .autoupdatingCurrent
        )
        // A sign-in whose end date passed, or that a status check found signed out, is the same
        // notice as a call that failed signed out: whichever comes first raises it.
        for tool in signedOut {
            let issue: SetupIssue = tool == .claude ? .claudeSignedOut : .codexSignedOut
            if open[issue] == nil {
                open[issue] = SummaryNotices.signedOutMessage(tool, summarizing: summarizing)
            }
        }
        for issue in SummaryNotices.derivedIssues {
            if let message = open[issue] { raise(issue, message: message) } else { clear(issue) }
        }

        if order.contains(.claude), !signedOut.contains(.claude),
           let ends = SummaryAlerts.endingSoon(.claude, statuses: statuses, now: now) {
            raise(.claudeSignInEnding, message: NotificationCopy.signInEndingBody(
                .claude, expiresAt: ends, now: now, timeZone: .autoupdatingCurrent, locale: .autoupdatingCurrent))
        } else {
            clear(.claudeSignInEnding)
        }

        let plans = order.contains(where: { $0.tool != nil })
        let waiting = plans
            ? try? queries.waitingCount(capturedBefore: now.addingTimeInterval(-SummaryNotices.pastDueAfter))
            : nil
        if let waiting, let message = SummaryNotices.backlogMessage(waiting: waiting, locale: .autoupdatingCurrent) {
            raise(.summariesWaiting, message: message)
        } else {
            clear(.summariesWaiting)
        }

        postSummaryAlerts(
            db: db, order: order, statuses: statuses, signedOut: signedOut,
            summarizing: summarizing, waiting: waiting, now: now)
        settleUnavailable(db: db, order: order, skips: skips, signedOut: signedOut, summarizing: summarizing, now: now)

        // A sign-in that stopped working is asked about again every five minutes, so signing
        // back in is noticed without opening a window; otherwise every six hours (and at launch,
        // when nothing was asked yet), so a sign-in's end date is known days ahead.
        let checkedAgo = now.timeIntervalSince(subscriptionStatusCheckedAt ?? .distantPast)
        let failing = skips.contains { skip in
            switch skip.kind {
            case .signedOut, .notSubscription: true
            default: false
            }
        }
        if plans, (failing && checkedAgo > 5 * 60) || checkedAgo > Self.subscriptionStatusInterval {
            refreshSubscriptionStatuses()
        }
    }

    /// How often `claude auth status` and `codex login status` are asked while nothing is wrong.
    static let subscriptionStatusInterval: TimeInterval = 6 * 3600

    /// Posts the notifications `SummaryAlerts` says are due, once each, and keeps its memory in
    /// `app_state`. Each one is already an in-app notice through `refreshSummaryNotices`, so the
    /// banner is not mirrored, and `.other` never raises the macOS question on its own.
    private func postSummaryAlerts(
        db: Database, order: [SummaryProvider], statuses: [SubscriptionTool: SubscriptionStatus],
        signedOut: Set<SubscriptionTool>, summarizing: SummaryProvider?, waiting: Int?, now: Date
    ) {
        let store = AppStateStore(db)
        let before = SummaryAlerts.Memory.decode((try? store.get(SummaryAlerts.memoryKey)) ?? nil)
        let (alerts, after) = SummaryAlerts.due(
            memory: before, order: order, statuses: statuses, signedOut: signedOut, waiting: waiting, now: now)
        if after != before { try? store.set(SummaryAlerts.memoryKey, after.encoded) }
        for alert in alerts {
            switch alert {
            case .signInEnding(let tool, let expiresAt):
                postBanner(
                    title: NotificationCopy.signInEndingTitle(tool),
                    body: NotificationCopy.signInEndingBody(
                        tool, expiresAt: expiresAt, now: now,
                        timeZone: .autoupdatingCurrent, locale: .autoupdatingCurrent),
                    identifier: "summary-sign-in-ending-\(tool.rawValue)",
                    mirrorAsNotice: false, moment: .other)
            case .signInEnded(let tool):
                postBanner(
                    title: NotificationCopy.signInEndedTitle(tool),
                    body: NotificationCopy.signInEndedBody(tool, summarizing: summarizing),
                    identifier: "summary-sign-in-ended-\(tool.rawValue)",
                    mirrorAsNotice: false, moment: .other)
            case .screenshotsWaiting(let count):
                postBanner(
                    title: NotificationCopy.screenshotsWaitingTitle,
                    body: NotificationCopy.screenshotsWaitingBody(count, locale: .autoupdatingCurrent),
                    identifier: "summary-screenshots-waiting",
                    mirrorAsNotice: false, moment: .other)
            }
        }
    }

    /// Tells the day's rollover why waiting screenshots are waiting, and puts the ones set aside
    /// as `unavailable` back in the queue when something can summarize again.
    private func settleUnavailable(
        db: Database, order: [SummaryProvider], skips: [SummaryNotices.Skip],
        signedOut: Set<SubscriptionTool>, summarizing: SummaryProvider?, now: Date
    ) {
        let reason = SummaryAlerts.staleReason(order: order, skips: skips, signedOut: signedOut, now: now)
        if let cost { Task { await cost.setStaleReason(reason) } }
        let available = summarizing != nil
        defer { summaryAvailable = available }
        guard available, summaryAvailable != true else { return }
        let requeued = (try? CaptureStore(db).requeueUnavailableSkipped()) ?? 0
        guard requeued > 0 else { return }
        Log.ui.info("summaries: \(requeued) screenshots set aside while nothing could summarize are waiting again")
        Task { await describe?.nudge() }
    }
}
