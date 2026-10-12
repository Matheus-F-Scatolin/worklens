import AppKit
import ArgumentParser
import Foundation
import SwiftUI
import WorklensCore

/// `worklens render-demo --out <dir>`: the README's screenshots, drawn offscreen.
///
/// It builds the same sample week the tour opens (`AppModel.presentSampleWeek()`, which writes
/// only under `DATA_DIR/sample-week`), hosts the real rail with the Today page and then the Weeks
/// page in a borderless window that is never ordered in, and writes each as a PNG at 2x. No
/// window server capture and no Screen Recording permission. Hidden from `--help`: it is a
/// developer's tool, and running it under a throwaway `HOME` keeps it away from a real install.
struct RenderDemoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "render-demo",
        abstract: "Render the sample week's Today and Weeks pages to PNG files.",
        shouldDisplay: false
    )

    @Option(help: "The folder the PNGs are written to.")
    var out: String

    @Option(help: "Width of the page in points.")
    var width: Double = 1140

    @Option(help: "Height of the page in points.")
    var height: Double = 750

    func run() async throws {
        let folder = Config.expandPath(out, cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let failure = await DemoRenderer.render(into: folder, size: CGSize(width: width, height: height)) {
            throw CLIFailure.config(failure)
        }
    }
}

@MainActor
private enum DemoRenderer {
    /// Returns a sentence when something did not draw, nil when both files were written.
    static func render(into folder: URL, size: CGSize) async -> String? {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .aqua)

        let model = AppModel.shared
        Task { await model.presentSampleWeek() }
        guard await wait(until: { model.isShowingSampleWeek && model.readerDocument?.waterfall != nil },
                   timeout: 30)
        else { return "the sample week did not load" }

        // The richest sample day: the most bars, then the most active time.
        let days = model.readerWeeks.flatMap(\.days).map(\.day)
        var best: (day: String, bars: Int, minutes: Int)?
        for day in days {
            model.select(.day(day))
            guard await wait(until: { isLoaded(model, day: day) }, timeout: 10),
                  let chart = model.readerDocument?.waterfall
            else { continue }
            let candidate = (day, chart.steps.count, chart.activeMinutes)
            if best == nil || (candidate.1, candidate.2) > (best!.bars, best!.minutes) {
                best = candidate
            }
        }
        guard let best else { return "no sample day has a chart" }
        model.select(.day(best.day))
        guard await wait(until: { isLoaded(model, day: best.day) }, timeout: 10)
        else { return "the Today page did not load" }
        guard await write(page(model, .today), size: size, to: folder.appendingPathComponent("today.png"))
        else { return "the Today page did not draw" }

        // The newest week with five days in it, so a week that began today is not the picture.
        model.readerPlace = .weeks
        guard let week = model.readerWeeks.first(where: { $0.days.count >= 5 }) ?? model.readerWeeks.first
        else { return "the sample has no week" }
        model.select(.week(week.monday))
        guard await wait(until: { model.readerDocument?.kind == .weekly && !model.readerLoading }, timeout: 10)
        else { return "the Weeks page did not load" }
        guard await write(page(model, .weeks), size: size, to: folder.appendingPathComponent("week.png"))
        else { return "the Weeks page did not draw" }
        print("today.png (\(best.day)) and week.png written to \(folder.path)")
        return nil
    }

    private static func isLoaded(_ model: AppModel, day: String) -> Bool {
        guard !model.readerLoading, case .day(day)? = model.readerSelection else { return false }
        return model.readerDocument?.waterfall != nil
    }

    /// The rail and one page, as `ReaderView` lays them out, without the sample ribbon.
    private static func page(_ model: AppModel, _ place: ReaderPlace) -> some View {
        HStack(spacing: 0) {
            ReaderRail(model: model)
            Group {
                if place == .today {
                    TodayPage(model: model)
                } else if let document = model.readerDocument {
                    WeekPage(model: model, document: document)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ReaderTheme.canvas)
        .foregroundStyle(ReaderTheme.text)
        .environment(\.colorScheme, .light)
        // A still picture: the bars land at their height instead of rising into it.
        .transaction { $0.disablesAnimations = true; $0.animation = nil }
    }

    private static func write(_ view: some View, size: CGSize, to url: URL) async -> Bool {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.backingType = .buffered
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        // Lets the views' own tasks run (they need the main actor) and AppKit lay them out.
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(40))
            spinRunLoop(0.02)
        }
        host.layoutSubtreeIfNeeded()
        host.display()

        let pixels = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )
        guard let pixels else { return false }
        pixels.size = size
        host.cacheDisplay(in: host.bounds, to: pixels)
        guard let png = pixels.representation(using: .png, properties: [:]) else { return false }
        do { try png.write(to: url) } catch { return false }
        window.contentView = nil
        return true
    }

    /// One short turn of the main run loop, for AppKit's layout and display passes.
    private static func spinRunLoop(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Yields the main actor, so the model's own tasks can run, until `done` holds.
    private static func wait(until done: () -> Bool, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return done()
    }
}
