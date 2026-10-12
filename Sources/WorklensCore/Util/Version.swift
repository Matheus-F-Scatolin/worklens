import Foundation

/// The version this build reports (#130).
///
/// It used to be a hand-edited constant under a "keep in sync with `CFBundleShortVersionString`"
/// comment, which is the kind of comment that is true right up until it is not: after 168 commits
/// every build ever made still said `0.1.0`. The bundle now derives both numbers from git —
/// `scripts/bundle.sh` stamps `CFBundleShortVersionString` from the nearest `v*` tag and
/// `CFBundleVersion` from `git rev-list --count HEAD` — and this reads them back, so there is one
/// source of truth and it is the tag.
///
/// `fallback` is what a build with no `Info.plist` of its own reports: `swift run Worklens`, the
/// test bundle, and a bundle cut from a tree that has no tag yet.
public enum WorklensVersion {
    /// The marketing version this build reports, e.g. `0.1.0`. Always one to three dot-separated
    /// integers, because Finder and most installers refuse to read anything else; that is why
    /// `bundle.sh` uses `git describe --abbrev=0` and not the `--always --dirty` form.
    public static let short = current.short

    public struct Numbers: Equatable, Sendable {
        public let short: String
        public let build: String

        public init(short: String, build: String) {
            self.short = short
            self.build = build
        }
    }

    /// What a build with no Info dictionary of its own reports. Not "the version": the version
    /// lives in the tag.
    ///
    /// Matches the values checked into `Resources/Info.plist`, which are the same fallback seen
    /// from the other side: what a bundle reports when `bundle.sh` found no tag to overwrite them
    /// with.
    public static let fallback = Numbers(short: "0.1.0", build: "1")

    /// Reads the two version keys out of an Info dictionary, per key, with `fallback` standing in
    /// for anything missing or empty.
    ///
    /// Injectable for the same reason `BuildStamp(info:)` is (`Util/BuildStamp.swift`): a pure
    /// function over a dictionary is testable, and reaching for `Bundle.main` inside it would let
    /// the *test runner's* `CFBundleShortVersionString` decide the app's version under
    /// `make test`.
    public static func numbers(from info: [String: Any]?) -> Numbers {
        func string(_ key: String) -> String? {
            guard let value = info?[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        return Numbers(
            short: string("CFBundleShortVersionString") ?? fallback.short,
            build: string("CFBundleVersion") ?? fallback.build
        )
    }

    /// The live answer for this process.
    ///
    /// `BundleLayout.infoDictionary` rather than `Bundle.main.infoDictionary` for the reason
    /// spelled out on `BuildStamp.current` — through the `worklens` symlink `Bundle.main` is
    /// `/usr/local/bin` and carries no `Info.plist` — and with no `Bundle.main` fallback behind
    /// it, because under `make test` that fallback is the test runner's own bundle and the suite
    /// would be asserting against Swift Testing's version number.
    static let current = numbers(
        from: BundleLayout.infoDictionary(forExecutable: BundleLayout.resolvedExecutableURL())
    )
}
