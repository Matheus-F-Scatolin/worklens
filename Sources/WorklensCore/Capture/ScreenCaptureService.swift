import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

// MARK: - Types

/// One screenshot, still in memory. `ImagePipeline` turns it into something small enough to store.
public struct CapturedFrame: Sendable {
    public let image: CGImage
    /// The display the window is (mostly) on, or the display that was photographed.
    public let displayID: CGDirectDisplayID
    /// The window's size in points, or the display's for a whole-display capture (the image is
    /// that size at 1x).
    public let pointSize: CGSize
    public let capturedAt: Date
    /// The one window in the picture. Nil only for `capture-once`'s whole-display screenshot,
    /// which never leaves the machine; every screenshot the scheduler keeps carries one.
    public let windowID: CGWindowID?

    public init(
        image: CGImage,
        displayID: CGDirectDisplayID,
        pointSize: CGSize,
        capturedAt: Date,
        windowID: CGWindowID? = nil
    ) {
        self.image = image
        self.displayID = displayID
        self.pointSize = pointSize
        self.capturedAt = capturedAt
        self.windowID = windowID
    }

    public var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }
}

public enum CaptureError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Screen Recording is off for this binary, or the user declined the monthly re-authorization.
    case permissionDenied
    case noDisplay
    /// The frontmost app has no window that could be photographed on its own: nothing on
    /// screen, only a panel, or the window closed before the picture was taken.
    case noWindow
    case captureFailed(underlying: String)

    public var description: String {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission is not granted"
        case .noDisplay:
            return "No display is available to capture"
        case .noWindow:
            return "No focused window is available to capture"
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

// MARK: - Focused window selection (pure)

/// One entry of `CGWindowListCopyWindowInfo`, reduced to what picking the focused window needs.
/// None of these fields needs Screen Recording; the window's name, which does, is not read here.
public struct WindowCandidate: Sendable, Equatable {
    public let windowID: CGWindowID
    public let ownerPID: pid_t
    public let layer: Int
    public let alpha: Double
    /// Global CoreGraphics bounds: top-left origin, the same space as `CGDisplayBounds`.
    public let bounds: CGRect

    public init(windowID: CGWindowID, ownerPID: pid_t, layer: Int = 0, alpha: Double = 1, bounds: CGRect) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.layer = layer
        self.alpha = alpha
        self.bounds = bounds
    }
}

/// Which window a screenshot is of (security finding #1). The scheduler photographs one window,
/// the frontmost app's focused one, so a blocked app beside it is never in the picture.
public enum FocusedWindowSelector {
    /// Smaller than this on either side is a helper surface (Chrome keeps a few), not a window
    /// anyone is looking at.
    public static let minimumSide: CGFloat = 40

    /// The first normal (layer 0), visible, window-sized entry owned by `pid`. The window list is
    /// front-to-back, so that is the focused window. Nil when the app has none on screen.
    public static func select(_ windows: [WindowCandidate], pid: pid_t) -> WindowCandidate? {
        windows.first {
            $0.ownerPID == pid && $0.layer == 0 && $0.alpha > 0
                && $0.bounds.width >= minimumSide && $0.bounds.height >= minimumSide
        }
    }

    /// Parses `CGWindowListCopyWindowInfo`'s dictionaries, keeping the order. An entry missing a
    /// field it needs is dropped rather than guessed at.
    public static func candidates(fromWindowList raw: [[String: Any]]) -> [WindowCandidate] {
        raw.compactMap { entry in
            guard let number = entry[kCGWindowNumber as String] as? Int,
                  let owner = entry[kCGWindowOwnerPID as String] as? Int,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            return WindowCandidate(
                windowID: CGWindowID(number),
                ownerPID: pid_t(owner),
                layer: layer,
                alpha: entry[kCGWindowAlpha as String] as? Double ?? 1,
                bounds: bounds
            )
        }
    }

    /// The display that holds most of `window`, so a window on the second monitor is recorded
    /// against the second monitor whatever the mouse is doing. Nil when it touches none.
    public static func displayID(for window: CGRect, displays: [DisplayCandidate]) -> CGDirectDisplayID? {
        var best: (id: CGDirectDisplayID, area: CGFloat)?
        for display in displays {
            let overlap = display.bounds.intersection(window)
            guard !overlap.isNull, !overlap.isEmpty else { continue }
            let area = overlap.width * overlap.height
            if best == nil || area > best!.area { best = (display.displayID, area) }
        }
        return best?.id
    }
}

// MARK: - Revalidation (pure)

/// The check between "the screenshot came back" and "the screenshot is kept" (security finding
/// #1). Taking the picture is asynchronous, and in that gap you can switch to a blocked app, or
/// a browser tab can move to a blocked site. The frame is kept only when the same window of the
/// same app is still in front and the policy still allows what is in it.
public enum CaptureRevalidation {
    /// The context half, shared by the screenshot and the text-only paths: same process, same
    /// app, same title and site, and still allowed.
    public static func contextStillValid(
        before: ForegroundContext, after: ForegroundContext, policy: PrivacyPolicy
    ) -> Bool {
        guard before.pid == after.pid, before.bundleID == after.bundleID else { return false }
        guard policy.decision(for: after) == .allow else { return false }
        guard before.signature == after.signature else { return false }
        // The private host is not in `signature` (it is never stored), so compare it here: a tab
        // that moved to another site while URL collection is off is still a different page.
        return before.policySite == after.policySite
    }

    /// The whole check for a screenshot: the context half, plus the window in the picture is
    /// still the app's focused window. A frame with no window id is never kept.
    public static func screenshotStillValid(
        before: ForegroundContext,
        after: ForegroundContext,
        capturedWindowID: CGWindowID?,
        currentWindowID: CGWindowID?,
        policy: PrivacyPolicy
    ) -> Bool {
        guard let capturedWindowID, capturedWindowID == currentWindowID else { return false }
        return contextStillValid(before: before, after: after, policy: policy)
    }
}

// MARK: - Service

/// What the scheduler needs from screen capture. `CaptureScheduler` depends on this rather than
/// on the concrete service so its tests never touch ScreenCaptureKit or TCC.
public protocol ScreenCapturing: Sendable {
    func permissionState() async -> PermissionState
    /// A screenshot of `pid`'s focused window and nothing else: no other window, no desktop, no
    /// other display. Throws `CaptureError.noWindow` when that window cannot be resolved; there
    /// is deliberately no whole-display fallback.
    func captureFocusedWindow(pid: pid_t) async throws -> CapturedFrame
    /// `pid`'s focused window as of now, for `CaptureRevalidation` after the capture returns.
    func focusedWindowID(pid: pid_t) async -> CGWindowID?
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

    public func focusedWindowID(pid: pid_t) -> CGWindowID? {
        ScreenCaptureService.frontWindow(pid: pid)?.windowID
    }

    /// The window list is the one place that orders windows front to back; `SCShareableContent`
    /// does not promise an order, so it is only used to turn the chosen id into an `SCWindow`.
    static func frontWindow(pid: pid_t) -> WindowCandidate? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        return FocusedWindowSelector.select(FocusedWindowSelector.candidates(fromWindowList: raw), pid: pid)
    }

    public func captureFocusedWindow(pid: pid_t) async throws -> CapturedFrame {
        do {
            guard let target = ScreenCaptureService.frontWindow(pid: pid) else {
                throw CaptureError.noWindow
            }
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true
            )
            guard let window = content.windows.first(where: { $0.windowID == target.windowID }),
                  window.owningApplication?.processID == pid
            else { throw CaptureError.noWindow }

            // One window, composited on its own: whatever overlaps it on screen, another app's
            // window included, is not in the picture, and neither is any other display.
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = max(1, Int(window.frame.width.rounded()))   // points → a 1x image
            config.height = max(1, Int(window.frame.height.rounded()))
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            config.capturesAudio = false
            config.ignoreShadowsSingleWindow = true

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )
            let displays = content.displays.map {
                DisplayCandidate(displayID: $0.displayID, bounds: CGDisplayBounds($0.displayID))
            }
            return CapturedFrame(
                image: image,
                displayID: FocusedWindowSelector.displayID(for: window.frame, displays: displays)
                    ?? CGMainDisplayID(),
                pointSize: window.frame.size,
                capturedAt: Date(),
                windowID: window.windowID
            )
        } catch let error as CaptureError {
            throw error
        } catch {
            throw mapped(error)
        }
    }

    /// A whole display, for `worklens capture-once` alone: it writes a PNG where you asked and
    /// sends nothing anywhere. The scheduler never calls this; see `captureFocusedWindow`.
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
