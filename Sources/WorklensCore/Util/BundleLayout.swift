import Darwin
import Foundation

/// Whether the running binary is the one inside `Worklens.app`, or the loose development build
/// (#119).
///
/// It matters because macOS treats them as two different applications: they carry different code
/// signatures, so a Screen Recording or Accessibility grant made for one does nothing for the
/// other. The CLI says which one you are talking to, once, on stderr.
///
/// Neither `Bundle.main.bundleIdentifier` nor `Bundle.main.bundlePath` answers this. Run through
/// the `worklens` symlink `make install` creates, `Bundle.main` is the *symlink's* directory —
/// `/usr/local/bin` — which has no `Info.plist`, so a correctly installed CLI looks exactly like
/// an unbundled one. Verified on this machine: through the symlink `bundleIdentifier` is nil.
///
/// So the question is asked of the executable itself: where does the file dyld actually loaded
/// live, once every symlink on the way is resolved? Inside `<name>.app/Contents/MacOS/` beside a
/// real `Info.plist`, or not.
public enum BundleLayout {
    /// The path dyld loaded, symlinks resolved. `_NSGetExecutablePath` rather than
    /// `CommandLine.arguments[0]`, which is whatever the caller passed — a bare `worklens` found
    /// on `PATH` is not a path at all.
    public static func resolvedExecutableURL() -> URL? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        let path = String(cString: buffer)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }

    /// The pure rule, so it can be tested without an app bundle: `…/<name>.app/Contents/MacOS/x`
    /// with an `Info.plist` beside `MacOS`. The `Info.plist` check is what keeps a directory
    /// someone happened to name `Foo.app` from counting.
    public static func isInsideAppBundle(
        executable: URL?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        guard let executable else { return false }
        let macOS = executable.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS",
              contents.lastPathComponent == "Contents",
              app.pathExtension == "app"
        else { return false }
        return fileExists(contents.appendingPathComponent("Info.plist").path)
    }

    /// The live answer for this process.
    public static var isBundled: Bool { isInsideAppBundle(executable: resolvedExecutableURL()) }

    /// The `Info.plist` of the `.app` this executable lives in, or nil when it lives in none.
    ///
    /// `Bundle.main.infoDictionary` is the obvious way to get this and is wrong for the same
    /// reason as above: run through the `worklens` symlink the main bundle is `/usr/local/bin`,
    /// so `BuildStamp` would report an unstamped build and `worklens version` would print a bare
    /// version number for an app that knows perfectly well which commit it is.
    public static func infoDictionary(forExecutable executable: URL?) -> [String: Any]? {
        guard let executable, isInsideAppBundle(executable: executable) else { return nil }
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        let plist = contents.appendingPathComponent("Info.plist")
        return NSDictionary(contentsOf: plist) as? [String: Any]
    }
}
