import Foundation
import Testing

/// The guard behind the bundle actually shipping an icon.
///
/// Notification Center caches an app's icon per *bundle identifier*, for the life of that daemon.
/// One launch of a `dev.worklens.app` whose bundle had no `AppIcon.icns` — which is what a
/// `make bundle` run against a checkout missing the file used to produce, with a warning nobody
/// reads — leaves every Worklens banner drawing a blank white tile, on every later build, until
/// the user restarts `NotificationCenter`. The bundle that caused it is long gone by then and
/// nothing about the app being blamed is wrong, which is why the file is checked rather than
/// assumed: `scripts/bundle.sh` now refuses to build without it, and this keeps it present.
///
/// Source-scanning through `#filePath` follows `NetworkDestinationsDocTests`. It stays offline:
/// the only thing read is this checkout.
@Suite("App icon")
struct AppIconTests {
    /// `Tests/WorklensCoreTests/<this file>` → the checkout.
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The icon types `iconutil` writes for a complete `.iconset`, smallest first. Notification
    /// Center draws the banner tile at around 32pt, the menu bar at 16pt and the Finder at 128pt
    /// and up, so "some icon is in there" is not enough — a file missing the small entries looks
    /// fine in the Finder and blurry or blank everywhere the app is actually seen.
    static let requiredTypes = [
        "ic04", "ic11", "ic05", "ic12", "ic07", "ic13", "ic08", "ic14", "ic09", "ic10",
    ]

    /// One `.icns` chunk: a four-character type, then its payload.
    struct Chunk {
        let type: String
        let payloadBytes: Int
    }

    /// Walks the flat chunk table an `.icns` is: an `icns` header with the total length, then
    /// `(type, length)` pairs where the length counts its own eight-byte header.
    static func chunks(of data: Data) throws -> [Chunk] {
        func be32(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 << 8 | Int(data[data.startIndex + offset + $1]) }
        }
        try #require(data.count > 8, "the file is too short to be an .icns")
        let magic = String(decoding: data[data.startIndex..<data.startIndex + 4], as: UTF8.self)
        #expect(magic == "icns")
        #expect(be32(4) == data.count, "the declared length does not match the file's size")

        var found: [Chunk] = []
        var offset = 8
        while offset + 8 <= data.count {
            let type = String(decoding: data[data.startIndex + offset..<data.startIndex + offset + 4],
                              as: UTF8.self)
            let length = be32(offset + 4)
            guard length >= 8, offset + length <= data.count else { break }
            found.append(Chunk(type: type, payloadBytes: length - 8))
            offset += length
        }
        return found
    }

    @Test("Info.plist's CFBundleIconFile names a file the bundle ships")
    func iconFileExists() throws {
        let plist = Self.repoRoot.appendingPathComponent("Resources/Info.plist")
        let contents = try Data(contentsOf: plist)
        let parsed = try PropertyListSerialization.propertyList(from: contents, format: nil)
        let name = try #require((parsed as? [String: Any])?["CFBundleIconFile"] as? String)

        // CFBundleIconFile may or may not carry the extension; macOS adds `.icns` when it does not.
        let icns = Self.repoRoot
            .appendingPathComponent("Resources")
            .appendingPathComponent(name.hasSuffix(".icns") ? name : name + ".icns")
        #expect(
            FileManager.default.fileExists(atPath: icns.path),
            "Info.plist names \(name) but Resources/\(icns.lastPathComponent) is missing — run `make icon`"
        )
    }

    @Test("the icon carries every size, none of them empty")
    func everySizeIsPresent() throws {
        let icns = Self.repoRoot.appendingPathComponent("Resources/AppIcon.icns")
        let found = try Self.chunks(of: try Data(contentsOf: icns))
        let byType = Dictionary(uniqueKeysWithValues: found.map { ($0.type, $0.payloadBytes) })

        for type in Self.requiredTypes {
            let bytes = byType[type]
            #expect(bytes != nil, "AppIcon.icns has no \(type) entry — re-run `make icon`")
            #expect((bytes ?? 0) > 0, "AppIcon.icns's \(type) entry is empty")
        }
    }
}
