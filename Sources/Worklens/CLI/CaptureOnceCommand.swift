import ArgumentParser
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WorklensCore

struct CaptureOnceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture-once",
        abstract: "Take one screenshot and write it as a PNG (exercises the permission flow)."
    )

    @Option(name: .long, help: "Where to write the PNG. Defaults to ./frame.png.")
    var out: String = "frame.png"

    @Option(name: .long, help: "Which display to capture: mouse | main.")
    var display: DisplayPreference = .mouse

    func run() async throws {
        _ = try CLIConfig.load()
        let service = ScreenCaptureService()

        // Shows the system dialog only the first time this binary asks; after that it is a
        // preflight. On the very first grant macOS requires a relaunch, hence the message below.
        if await service.permissionState() == .denied {
            _ = await service.requestPermission()
        }

        let started = Date()
        let frame: CapturedFrame
        do {
            frame = try await service.capture(preferring: display)
        } catch CaptureError.permissionDenied {
            try CaptureOnceCommand.failPermissionDenied()
        } catch let error as CaptureError {
            CaptureOnceCommand.printError(error.description)
            throw ExitCode.failure
        }
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)

        let destination = Config.expandPath(out, cwd: Config.currentDirectory)
        try CaptureOnceCommand.writePNG(frame.image, to: destination)

        print("display   \(frame.displayID) (\(display.rawValue))")
        print("points    \(Int(frame.pointSize.width))x\(Int(frame.pointSize.height))")
        print("pixels    \(frame.image.width)x\(frame.image.height)")
        print("elapsed   \(elapsedMs) ms")
        print("wrote     \(destination.path)")
    }

    /// Exit code 3 is the agreed "grant Screen Recording and try again" signal, so the scheduler
    /// (#6) and the menu bar (#15) can tell a permission problem from any other failure.
    private static func failPermissionDenied() throws -> Never {
        printError("""
            Screen Recording permission is not granted for this process.

            Open System Settings > Privacy & Security > Screen Recording and enable whatever runs
            Worklens (Terminal/iTerm for `swift run`, Worklens.app for the bundle), then run this
            command again: the first grant only takes effect after the process restarts. macOS
            re-asks roughly monthly; declining that dialog lands here too.

            \(HelpLink.screenRecordingOff.repoRelativePath)
            """)
        throw ExitCode(3)
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            printError("Could not create a PNG at \(url.path)")
            throw ExitCode.failure
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            printError("Could not write \(url.path)")
            throw ExitCode.failure
        }
    }
}

extension DisplayPreference: ExpressibleByArgument {}
