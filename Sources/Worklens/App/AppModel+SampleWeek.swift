import AppKit
import Foundation
import SwiftUI
import WorklensCore

/// The sample week (#349) and its handoff to your first real summary (#350).
///
/// The sample is its own database (`SampleWeek.directory`), and the reader is the only thing in
/// the app that is ever pointed at it: `readerDB` is what `AppModel+Reader.swift` reads, and
/// every other service (capture, describe, search, cost, retention, deletes, the MCP server and
/// the CLI) keeps using the real ledger. The rules about when to show it and when to hand over
/// are `SampleWeekHandoff`'s, in `WorklensCore`, with their tests.
///
/// The stored state is in `AppModel.swift`, beside the reader's; this file is its only writer.
@MainActor
extension AppModel {
    /// The database the reader reads: the sample's while it is shown, the ledger otherwise.
    var readerDB: Database? { isShowingSampleWeek ? sampleWeekDB : db }

    /// The ribbon's second line, or nil while the welcome is still open or once the handoff to
    /// your own days has happened.
    var sampleWeekStatusLine: String? {
        SampleWeekHandoff.statusLine(
            setup: setupProgress, handedOff: sampleWeekHandedOff,
            scheduler: state.scheduler, locale: .autoupdatingCurrent
        )
    }

    // MARK: The seam (#349): other issues call these three by name

    /// Builds the sample database if needed, points the reader at it and lands on Today.
    func showSampleWeek() {
        closeSettings()
        Task { [weak self] in await self?.presentSampleWeek() }
    }

    /// Points the reader back at the real ledger. Leaving by hand also means the sample is not
    /// shown by itself again; Settings → Advanced still brings it back.
    func leaveSampleWeek() {
        if let db, !sampleWeekHandedOff {
            try? AppStateStore(db).setDate(SampleWeekHandoff.Key.leftAt, Date())
        }
        exitSampleWeek()
    }

    // MARK: Launch

    /// Decided once, before capture starts: show the sample, stay closed, or record an install
    /// that already has summaries as handed over, so it is never told its day has started.
    func prepareSampleWeek() {
        guard let db else { return }
        let facts = SampleWeekHandoff.Facts.read(db)
        switch SampleWeekHandoff.atLaunch(facts) {
        case .nothing:
            sampleWeekHandedOff = true
        case .recordSilently:
            try? AppStateStore(db).setDate(SampleWeekHandoff.Key.handedOffAt, Date())
            sampleWeekHandedOff = true
            Log.ui.info("sample week: this install already has summaries; recorded as handed over")
        case .handOver:
            // Your first summaries landed while the app was not watching: the same one banner.
            sampleWeekHandedOff = true
            try? AppStateStore(db).setDate(SampleWeekHandoff.Key.handedOffAt, Date())
            Log.ui.info("sample week: your first summaries arrived while closed; handing over")
            postSampleWeekBanner()
            removeSampleFolderIfHandedOff()
        case .stayClosed:
            sampleWeekHandedOff = false
        case .show:
            sampleWeekHandedOff = false
            Log.ui.info("sample week: nothing summarized yet, so the reader opens on the sample")
            Task { [weak self] in await self?.presentSampleWeek() }
        }
    }

    // MARK: Showing and leaving

    /// One build at a time: a second call while the first is still writing (the launch's
    /// auto-show racing a tour's `showSampleWeek()`, say) waits on that build instead of
    /// starting another on the same folder, and whichever call resumes first adopts it.
    func presentSampleWeek() async {
        if isShowingSampleWeek, sampleWeekDB != nil {
            showToday()
            return
        }
        if !isShowingSampleWeek {
            isShowingSampleWeek = true
            clearReaderForSwap()
        }
        let build = sampleWeekBuild ?? startSampleWeekBuild()
        let result = await build.result
        if sampleWeekBuild == build { sampleWeekBuild = nil }
        // Left while it was being built (exiting already went back to your days), or another
        // call already adopted this build.
        guard isShowingSampleWeek, sampleWeekDB == nil else { return }
        switch result {
        case .success(let sample):
            sampleWeekDB = sample
        case .failure(let error):
            Log.ui.warn("sample week: could not build it; the reader stays on your own days")
            Log.ui.debug("sample week build failed: \(error)")
            isShowingSampleWeek = false
        }
        await refreshReaderIndex()
        landAfterSampleSwap()
    }

    /// Today, unless a tour moved on while the sample was being built: then the stop it is on.
    private func landAfterSampleSwap() {
        if tour.isRunning, let place = tour.state?.stop.readerPlace, place != .today {
            show(place)
        } else {
            showToday()
        }
    }

    /// Rebuilt on every show: the dates move with today, and a few hundred rows are cheaper to
    /// write again than to keep in step. Waits for a pending removal so it cannot delete the
    /// new folder.
    private func startSampleWeekBuild() -> Task<Database, Error> {
        let dataDir = config.dataDir
        let removal = sampleWeekRemoval
        let build = Task.detached(priority: .userInitiated) {
            await removal?.value
            return try SampleWeek.rebuild(dataDir: dataDir)
        }
        sampleWeekBuild = build
        return build
    }

    /// Back to the real ledger, with a short fade, or none under Reduce Motion.
    func exitSampleWeek() {
        guard isShowingSampleWeek else { return }
        Task { [weak self] in await self?.fadeToYourDays() }
    }

    /// Your own index and Today are read while the sample is still on screen, then swapped in
    /// inside one animation, so the fade lands on your real Today rather than on a spinner.
    private func fadeToYourDays() async {
        guard let db else {
            isShowingSampleWeek = false
            sampleWeekDB = nil
            clearReaderForSwap()
            return
        }
        let loaded = await readReaderIndex(db, paging: ReaderPaging())
        let entries = Dictionary(
            loaded.entries.map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let today = DayBoundaries.dayString(Date())
        let days = ReaderIndex.weeks(entries: loaded.entries).flatMap(\.days).map(\.day)
        let day = days.contains(today) || days.isEmpty ? today : days[0]
        let document = await buildReaderDocument(.day(day), db: db, entries: entries)
        // Left twice at once, or the other call already swapped.
        guard isShowingSampleWeek else { return }
        let fade: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? nil : .easeInOut(duration: 0.35)
        withAnimation(fade) {
            readerLoad?.cancel()
            isShowingSampleWeek = false
            sampleWeekDB = nil
            readerPaging = ReaderPaging()
            applyReaderIndex(loaded)
            readerPlace = .today
            readerSelection = .day(day)
            // Setting the selection started a load of the same page; this one is already read.
            readerLoad?.cancel()
            readerDocument = document
            readerLoading = false
        }
        removeSampleFolderIfHandedOff()
    }

    /// "Your day has started.": one banner, and if notifications are off nothing else, no menu
    /// notice and no nag.
    private func postSampleWeekBanner() {
        postBanner(
            title: SampleWeekCopy.startedTitle,
            body: SampleWeekCopy.startedBody,
            identifier: Notifier.sampleWeekHandoff,
            mirrorAsNotice: false
        )
    }

    /// Rebuilt on demand, so the folder has no reason to stay once you have days of your own.
    /// A build still in flight is waited for first, so the folder is not deleted under it.
    private func removeSampleFolderIfHandedOff() {
        guard sampleWeekHandedOff, !isShowingSampleWeek else { return }
        let dataDir = config.dataDir
        let build = sampleWeekBuild
        sampleWeekRemoval = Task.detached(priority: .utility) {
            _ = await build?.result
            SampleWeek.remove(dataDir: dataDir)
        }
    }

    /// Everything the reader holds about the database it was reading, so nothing from one is
    /// drawn over the other while the next index loads.
    private func clearReaderForSwap() {
        readerLoad?.cancel()
        readerIndexLoaded = false
        readerWeeks = []
        readerEntries = [:]
        readerPaging = ReaderPaging()
        readerSelection = nil
        readerDocument = nil
        readerLoading = false
        readerPlace = .today
    }

    // MARK: The handoff (#350)

    /// The describe worker summarized a screenshot into the real ledger.
    ///
    /// Synchronous up to the flag, so two summaries landing together cannot both hand over.
    func sampleWeekSummaryArrived(provider: String) {
        guard !sampleWeekHandedOff, let db else { return }
        let decision = SampleWeekHandoff.onSummary(
            provider: provider, isShowingSample: isShowingSampleWeek, handedOff: false
        )
        guard decision != .none else { return }
        if decision.record {
            sampleWeekHandedOff = true
            try? AppStateStore(db).setDate(SampleWeekHandoff.Key.handedOffAt, Date())
            Log.ui.info("sample week: your first summary arrived; handing over")
        }
        if decision.leave { exitSampleWeek() }
        if decision.notify { postSampleWeekBanner() }
        // Not on screen: the folder goes now. On screen, the fade removes it once it has swapped.
        removeSampleFolderIfHandedOff()
    }
}
