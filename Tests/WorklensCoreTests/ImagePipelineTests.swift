import CoreGraphics
import Foundation
import Testing
@testable import WorklensCore

// MARK: - Synthetic images

private enum Fixture {
    /// An RGB context matching what `downscale` produces, so fixtures and pipeline output agree.
    static func context(_ width: Int, _ height: Int) -> CGContext {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
    }

    static func solid(_ width: Int, _ height: Int, gray: Double) -> CGImage {
        let ctx = context(width, height)
        ctx.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// Horizontal black-to-white ramp, one fill per column.
    static func gradient(_ width: Int, _ height: Int) -> CGImage {
        let ctx = context(width, height)
        for x in 0..<width {
            let v = Double(x) / Double(max(width - 1, 1))
            ctx.setFillColor(red: v, green: v, blue: v, alpha: 1)
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        return ctx.makeImage()!
    }

    /// Left half black, right half white.
    static func halfAndHalf(_ width: Int, _ height: Int) -> CGImage {
        let ctx = context(width, height)
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return ctx.makeImage()!
    }

    /// Deterministic pseudo-random 8x8 blocks — enough entropy to defeat JPEG and dhash alike.
    static func noise(_ width: Int, _ height: Int, seed: UInt64 = 0x9E37_79B9_7F4A_7C15) -> CGImage {
        let ctx = context(width, height)
        var state = seed
        func next() -> Double {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Double(state % 256) / 255.0
        }
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                let v = next()
                ctx.setFillColor(red: v, green: v, blue: v, alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: 8, height: 8))
            }
        }
        return ctx.makeImage()!
    }

    /// `base` with a filled rectangle covering `fraction` of the area, in the middle.
    static func patched(_ base: CGImage, fraction: Double, gray: Double) -> CGImage {
        let ctx = context(base.width, base.height)
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        let side = (Double(base.width * base.height) * fraction).squareRoot()
        ctx.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
        ctx.fill(CGRect(
            x: Double(base.width) / 2 - side / 2,
            y: Double(base.height) / 2 - side / 2,
            width: side, height: side
        ))
        return ctx.makeImage()!
    }
}

// MARK: - Tests

@Suite("ImagePipeline.downscale")
struct DownscaleTests {
    @Test("longest edge lands on maxEdge and aspect ratio is preserved")
    func aspectRatio() {
        let wide = ImagePipeline.downscale(Fixture.gradient(3200, 1800), maxEdge: 1024)
        #expect(wide.width == 1024)
        #expect(wide.height == 576)   // 1800 * 1024/3200

        let tall = ImagePipeline.downscale(Fixture.gradient(1000, 2000), maxEdge: 500)
        #expect(tall.height == 500)
        #expect(tall.width == 250)
    }

    @Test("an image already within maxEdge is returned untouched")
    func neverUpscales() {
        let small = Fixture.solid(640, 400, gray: 0.5)
        let result = ImagePipeline.downscale(small, maxEdge: 1024)
        #expect(result.width == 640)
        #expect(result.height == 400)

        let exact = ImagePipeline.downscale(Fixture.solid(1024, 1024, gray: 0.5), maxEdge: 1024)
        #expect(exact.width == 1024)
    }

    @Test("degenerate sizes do not produce a zero-dimension image")
    func extremeRatios() {
        let sliver = ImagePipeline.downscale(Fixture.solid(4000, 3, gray: 0.5), maxEdge: 100)
        #expect(sliver.width == 100)
        #expect(sliver.height >= 1)
    }

    @Test("output is 8-bit sRGB with no alpha, so ImageIO can encode it")
    func outputFormat() {
        let result = ImagePipeline.downscale(Fixture.gradient(2048, 1280), maxEdge: 1024)
        #expect(result.bitsPerComponent == 8)
        #expect(result.alphaInfo == .noneSkipLast)
        #expect(ImagePipeline.jpegData(result, quality: 0.6) != nil)
    }
}

@Suite("ImagePipeline.jpegData")
struct JPEGTests {
    @Test("a 1024x640 gradient encodes to well under 400 KB")
    func gradientSize() throws {
        let data = try #require(ImagePipeline.jpegData(Fixture.gradient(1024, 640), quality: 0.6))
        #expect(data.count > 0)
        #expect(data.count < 400 * 1024)
        // JPEG SOI marker — this really is a JPEG.
        #expect(data.prefix(2) == Data([0xFF, 0xD8]))
    }

    @Test("even noise at quality 1.0 stays under 400 KB at 1024 px")
    func worstCaseSize() throws {
        let data = try #require(ImagePipeline.jpegData(Fixture.noise(1024, 640), quality: 1.0))
        #expect(data.count < 400 * 1024)
    }

    @Test("lower quality produces smaller output")
    func qualityMonotonic() throws {
        let image = Fixture.noise(1024, 640)
        let low = try #require(ImagePipeline.jpegData(image, quality: 0.2))
        let high = try #require(ImagePipeline.jpegData(image, quality: 0.9))
        #expect(low.count < high.count)
    }

    @Test("out-of-range quality is clamped rather than rejected")
    func clampsQuality() {
        let image = Fixture.solid(64, 64, gray: 0.5)
        #expect(ImagePipeline.jpegData(image, quality: -1) != nil)
        #expect(ImagePipeline.jpegData(image, quality: 5) != nil)
    }
}

@Suite("ImagePipeline.fingerprint and changeScore")
struct FingerprintTests {
    @Test("a fingerprint is a 32x32 thumbnail plus a 64-bit hash")
    func shape() {
        let fp = ImagePipeline.fingerprint(Fixture.gradient(1024, 640))
        #expect(fp.thumb.count == 32 * 32)
        #expect(fp.dhashHex.count == 16)
        #expect(fp.dhash != 0)   // a gradient has left-to-right structure
    }

    @Test("an identical frame scores exactly zero")
    func identical() {
        let image = Fixture.gradient(1024, 640)
        let a = ImagePipeline.fingerprint(image)
        let b = ImagePipeline.fingerprint(image)
        #expect(a == b)
        #expect(ImagePipeline.changeScore(a, a) == 0)
        #expect(ImagePipeline.changeScore(a, b) == 0)
    }

    @Test("solid black against solid white scores about 1.0")
    func opposites() {
        let black = ImagePipeline.fingerprint(Fixture.solid(1024, 640, gray: 0))
        let white = ImagePipeline.fingerprint(Fixture.solid(1024, 640, gray: 1))
        #expect(ImagePipeline.changeScore(black, white) > 0.98)
        #expect(ImagePipeline.changeScore(black, white) <= 1.0)
    }

    @Test("changeScore is symmetric")
    func symmetric() {
        let a = ImagePipeline.fingerprint(Fixture.gradient(800, 600))
        let b = ImagePipeline.fingerprint(Fixture.halfAndHalf(800, 600))
        #expect(ImagePipeline.changeScore(a, b) == ImagePipeline.changeScore(b, a))
    }

    @Test("a 2 % area change lands between 0.005 and 0.05")
    func smallChange() {
        let base = Fixture.solid(1024, 640, gray: 0.5)
        let patched = Fixture.patched(base, fraction: 0.02, gray: 0)
        let score = ImagePipeline.changeScore(
            ImagePipeline.fingerprint(base),
            ImagePipeline.fingerprint(patched)
        )
        #expect(score > 0.005)
        #expect(score < 0.05)
    }

    @Test("a window switch scores far above the 0.03 default threshold")
    func windowSwitch() {
        let score = ImagePipeline.changeScore(
            ImagePipeline.fingerprint(Fixture.gradient(1024, 640)),
            ImagePipeline.fingerprint(Fixture.noise(1024, 640))
        )
        #expect(score > 0.1)
    }

    @Test("a mismatched or empty thumbnail is treated as a full change")
    func mismatchedThumbs() {
        let real = ImagePipeline.fingerprint(Fixture.solid(64, 64, gray: 0.5))
        let empty = FrameFingerprint(dhash: 0, thumb: [])
        #expect(ImagePipeline.changeScore(real, empty) == 1)
        #expect(ImagePipeline.changeScore(empty, empty) == 1)
    }
}

@Suite("ImagePipeline.hamming")
struct HammingTests {
    @Test("symmetric, zero against itself, 64 against the complement")
    func basics() {
        let a: UInt64 = 0x0F1E_2D3C_4B5A_6978
        let b: UInt64 = 0xDEAD_BEEF_CAFE_F00D
        #expect(ImagePipeline.hamming(a, b) == ImagePipeline.hamming(b, a))
        #expect(ImagePipeline.hamming(a, a) == 0)
        #expect(ImagePipeline.hamming(a, ~a) == 64)
        #expect(ImagePipeline.hamming(0, 1) == 1)
    }

    @Test("near-identical frames have a small hash distance, unrelated ones a large one")
    func realFrames() {
        let base = Fixture.gradient(1024, 640)
        let near = ImagePipeline.fingerprint(Fixture.patched(base, fraction: 0.01, gray: 0))
        let same = ImagePipeline.fingerprint(base)
        let different = ImagePipeline.fingerprint(Fixture.noise(1024, 640))

        #expect(ImagePipeline.hamming(same.dhash, near.dhash) < 12)
        #expect(ImagePipeline.hamming(same.dhash, different.dhash) > 12)
    }
}

@Suite("ImagePipeline performance")
struct ImagePipelinePerformanceTests {
    @Test("a 4K frame downscales and fingerprints well inside the budget")
    func fourKBudget() {
        let image = Fixture.gradient(3840, 2160)
        // Warm up the CoreGraphics paths so the measurement is not first-call cost.
        _ = ImagePipeline.fingerprint(ImagePipeline.downscale(image, maxEdge: 1024))

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let small = ImagePipeline.downscale(image, maxEdge: 1024)
            _ = ImagePipeline.fingerprint(small)
        }
        // Target is < 60 ms on Apple silicon; assert < 250 ms so this stays CI-safe.
        #expect(elapsed < .milliseconds(250), "downscale + fingerprint took \(elapsed)")
    }
}

@Suite("ScreenshotPaths")
struct ScreenshotPathsTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let when = Date(timeIntervalSince1970: 1_757_000_000)   // 2025-09-04T15:33:20Z

    @Test("filenames are HHmmss_<id8>.jpg")
    func filename() {
        let name = ScreenshotPaths.filename(for: when, id: "0f1e2d3c-4b5a-6978-8899-aabbccddeeff", timeZone: utc)
        #expect(name == "153320_0f1e2d3c.jpg")
    }

    @Test("the relative path is what goes in captures.image_path")
    func relativePath() {
        let path = ScreenshotPaths.relativePath(for: when, id: "0f1e2d3c-4b5a", timeZone: utc)
        #expect(path == "screenshots/2025-09-04/153320_0f1e2d3c.jpg")
    }

    @Test("url creates the day folder and matches the relative path")
    func createsDirectory() throws {
        let dataDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worklens-shots-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let url = try ScreenshotPaths.url(for: when, id: "abcdef12-3456", dataDir: dataDir, timeZone: utc)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path,
                                               isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(url.path.hasSuffix(ScreenshotPaths.relativePath(for: when, id: "abcdef12-3456", timeZone: utc)))
    }

    @Test("a real JPEG round trips through the computed path")
    func writesAFrame() throws {
        let dataDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worklens-shots-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let jpeg = try #require(ImagePipeline.jpegData(
            ImagePipeline.downscale(Fixture.gradient(2048, 1280), maxEdge: 1024), quality: 0.6
        ))
        let url = try ScreenshotPaths.url(for: when, id: Identifiers.new(), dataDir: dataDir, timeZone: utc)
        try jpeg.write(to: url)
        #expect(try Data(contentsOf: url).count == jpeg.count)
    }
}

@Suite("ImagePipeline source hygiene")
struct ImagePipelineSourceTests {
    @Test("the pipeline stays free of AppKit and UIKit")
    func noUIFrameworks() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // Tests/WorklensCoreTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("Sources/WorklensCore/Capture/ImagePipeline.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(!text.contains("import AppKit"))
        #expect(!text.contains("import UIKit"))
        #expect(!text.contains("import SwiftUI"))
    }
}
