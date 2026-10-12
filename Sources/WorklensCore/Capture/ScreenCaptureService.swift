import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

// MARK: - Types

/// One screenshot, still in memory. `ImagePipeline` turns it into something small enough to store.
public struct CapturedFrame: Sendable {
    public let image: CGImage
    public let displayID: CGDirectDisplayID
    /// The display's size in points (the image is that size at 1x).
    public let pointSize: CGSize
    public let capturedAt: Date

    public init(image: CGImage, displayID: CGDirectDisplayID, pointSize: CGSize, capturedAt: Date) {
        self.image = image
        self.displayID = displayID
        self.pointSize = pointSize
        self.capturedAt = capturedAt
    }

    public var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }
}

public enum CaptureError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Screen Recording is off for this binary, or the user declined the monthly re-authorization.
    case permissionDenied
    case noDisplay
    case captureFailed(underlying: String)

    public var description: String {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission is not granted"
        case .noDisplay:
            return "No display is available to capture"
        case let .captureFailed(underlying):
            return "Capture failed: \(underlying)"
        }
    }
}

public enum PermissionState: Sendable, Equatable {
    /// `.unknown` is reserved: `CGPreflightScreenCaptureAccess` only answers yes or no, so the
    /// live service returns `.granted`/`.denied`. Callers still switch over three cases so a
    /// future "not yet asked" signal does not break them.
    case granted, denied, unknown
}

/// Which display a capture should target.
public enum DisplayPreference: String, Sendable, CaseIterable {
    /// The display the mouse cursor is on, falling back to the main display.
    case mouse
    /// The main display, regardless of where the cursor is.
    case main
}

// MARK: - Display selection (pure)

/// A display reduced to what selection needs, so the rule can be unit-tested without
/// ScreenCaptureKit or real hardware.
public struct DisplayCandidate: Sendable, Equatable {
    public let displayID: CGDirectDisplayID
    /// Global CoreGraphics bounds: top-left origin, main display at (0, 0).
    public let bounds: CGRect

    public init(displayID: CGDirectDisplayID, bounds: CGRect) {
        self.displayID = displayID
        self.bounds = bounds
    }
}

public enum DisplaySelector {
    /// The display under `mouse`, else the main display, else the first one. Nil for an empty list.
    ///
    /// `mouse` must be in global CG coordinates (top-left origin) — the same space as
    /// `CGDisplayBounds`, which is why the service reads `CGEvent(source: nil)?.location`
    /// and not `NSEvent.mouseLocation` (bottom-left origin).
    public static func select(
        displays: [DisplayCandidate],
        mouse: CGPoint?,
        mainDisplayID: CGDirectDisplayID,
        preference: DisplayPreference = .mouse
    ) -> DisplayCandidate? {
        if preference == .mouse, let mouse, let hit = displays.first(where: { $0.bounds.contains(mouse) }) {
            return hit
        }
        return displays.first { $0.displayID == mainDisplayID } ?? displays.first
    }
}

// MARK: - Service

/// What the scheduler needs from screen capture. `CaptureScheduler` depends on this rather than
/// on the concrete service so its tests never touch ScreenCaptureKit or TCC.
public protocol ScreenCapturing: Sendable {
    func permissionState() async -> PermissionState
    func capture() async throws -> CapturedFrame
}

/// One-shot screenshots via `SCScreenshotManager`, plus the Screen Recording permission lifecycle.
///
/// Never starts an `SCStream` and never captures audio: a screenshot is a single call.
public actor ScreenCaptureService: ScreenCapturing {
    /// `CGRequestScreenCaptureAccess()` prompts only the first time per binary; calling it again
    /// after a denial does nothing but can confuse the user, so we call it at most once per launch.
    private var didRequestPermission = false

    public init() {}

    // MARK: Permission

    public func permissionState() -> PermissionState {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    /// Prompts for Screen Recording, at most once per app launch. Returns the state afterwards.
    @discardableResult
    public func requestPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        guard !didRequestPermission else { return false }
        didRequestPermission = true
        return CGRequestScreenCaptureAccess()
    }

    /// Opens System Settings → Privacy & Security → Screen Recording.
    public static func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        else { return }
        // NSWorkspace is AppKit: hop to the main thread rather than whatever thread called us.
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }

    // MARK: Capture

    public func capture() async throws -> CapturedFrame {
        try await capture(preferring: .mouse)
    }

    public func capture(preferring preference: DisplayPreference) async throws -> CapturedFrame {
        // `SCShareableContent` needs the same permission as the screenshot itself, so both live
        // inside one do/catch and map to the same error.
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            let candidates = content.displays.map {
                DisplayCandidate(displayID: $0.displayID, bounds: CGDisplayBounds($0.displayID))
            }
            guard let chosen = DisplaySelector.select(
                displays: candidates,
                mouse: CGEvent(source: nil)?.location,
                mainDisplayID: CGMainDisplayID(),
                preference: preference
            ), let display = content.displays.first(where: { $0.displayID == chosen.displayID })
            else { throw CaptureError.noDisplay }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.width       // points → a 1x image; ImagePipeline downscales anyway
            config.height = display.height
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            config.capturesAudio = false

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )
            return CapturedFrame(
                image: image,
                displayID: display.displayID,
                pointSize: CGSize(width: display.width, height: display.height),
                capturedAt: Date()
            )
        } catch let error as CaptureError {
            throw error
        } catch {
            throw mapped(error)
        }
    }

    private func mapped(_ error: Error) -> CaptureError {
        CaptureError.classify(error, permissionState: permissionState())
    }
}

public extension CaptureError {
    /// TCC failures surface as `SCStreamError.userDeclined` (-3801), but a permission revoked
    /// mid-flight can also fail in less specific ways, so preflight is the second opinion.
    /// Pure, so the mapping is testable without provoking a real denial.
    static func classify(_ error: Error, permissionState: PermissionState) -> CaptureError {
        if let captureError = error as? CaptureError { return captureError }
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.Code.userDeclined.rawValue {
            return .permissionDenied
        }
        if permissionState == .denied { return .permissionDenied }
        return .captureFailed(underlying: error.localizedDescription)
    }
}
