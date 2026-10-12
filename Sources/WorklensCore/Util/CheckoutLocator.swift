import Foundation

/// Finds the checkout a running Worklens was built from (#119).
///
/// It lives here, and takes its filesystem test as a closure, because the answer decides whether
/// the menu offers "Update and restart…" and whether the app auto-updates at all — and that is
/// too consequential to be only testable by launching the app.
///
/// Two candidates, in order:
///
/// 1. `WLRepoPath`, the absolute checkout path `scripts/bundle.sh` stamps into the bundle's
///    `Info.plist`. The only one that survives `make install` copying the bundle to
///    `/Applications`; before it existed, installing the app silently turned updating off.
/// 2. The bundle's grandparent, which is the checkout when the app is still where `make bundle`
///    left it (`<repo>/build/Worklens.app`). Kept for bundles built before the stamp.
///
/// Either way the directory still has to look like a checkout when the question is asked. A
/// repository deleted, renamed or moved after the build answers nil — no update item is a better
/// outcome than one that fails halfway through replacing a running app.
public enum CheckoutLocator {
    /// - Parameters:
    ///   - stampedPath: `BuildStamp.repoPath`, nil for an unstamped or pre-#119 bundle.
    ///   - bundleURL: `Bundle.main.bundleURL` — the `.app` itself, not its binary.
    ///   - isCheckout: whether a directory is this project's checkout.
    public static func resolve(
        stampedPath: String?,
        bundleURL: URL,
        isCheckout: (URL) -> Bool
    ) -> URL? {
        let grandparent = bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [stampedPath.map { URL(fileURLWithPath: $0) }, grandparent]
        return candidates.compactMap { $0 }.first(where: isCheckout)
    }

    /// The real test: the script an update runs, and the manifest that script builds.
    public static func looksLikeCheckout(_ root: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.isExecutableFile(atPath: root.appendingPathComponent("scripts/update.sh").path)
            && fileManager.fileExists(atPath: root.appendingPathComponent("Package.swift").path)
    }
}
