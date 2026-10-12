import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A tiny, cheap summary of one frame. Two of these are all that is needed to decide whether the
/// screen changed enough to be worth a vision call.
public struct FrameFingerprint: Sendable, Codable, Equatable {
    /// 8x8 difference hash, derived from a 9x8 grayscale reduction.
    public let dhash: UInt64
    /// 32x32 grayscale luminance, row-major.
    public let thumb: [UInt8]

    public init(dhash: UInt64, thumb: [UInt8]) {
        self.dhash = dhash
        self.thumb = thumb
    }

    /// The 16 hex characters stored in `captures.dhash`.
    public var dhashHex: String { String(format: "%016llx", dhash) }
}

/// Downscaling, JPEG encoding and change detection. Pure CoreGraphics + ImageIO: no AppKit, no
/// third-party image libraries, nothing that needs a run loop.
public enum ImagePipeline {
    /// Side length of the luminance thumbnail behind `changeScore`.
    public static let thumbSide = 32
    /// Width of the grayscale reduction behind `dhash` (height is `dhashHeight`).
    static let dhashWidth = 9
    static let dhashHeight = 8

    // MARK: Downscale

    /// Scales so the longest edge equals `maxEdge`, preserving aspect ratio. Never upscales:
    /// an image already within `maxEdge` is returned unchanged.
    public static func downscale(_ image: CGImage, maxEdge: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard maxEdge > 0, longest > maxEdge else { return image }

        let scale = Double(maxEdge) / Double(longest)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    // MARK: JPEG

    /// Quality every stored and sent JPEG is written at (0...1). Was `CAPTURE_JPEG_QUALITY`
    /// until #87; 0.6 is where a 1024 px frame stays legible to the describer at ~60 KB.
    public static let jpegQuality = 0.6

    /// JPEG bytes at `quality` (0...1). Nil only if ImageIO refuses the image.
    public static func jpegData(_ image: CGImage, quality: Double = jpegQuality) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: min(max(quality, 0), 1)
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: Fingerprint

    /// The 32x32 luminance thumbnail plus the 8x8 difference hash.
    public static func fingerprint(_ image: CGImage) -> FrameFingerprint {
        let thumb = grayscale(image, width: thumbSide, height: thumbSide)
        let small = grayscale(image, width: dhashWidth, height: dhashHeight)

        var hash: UInt64 = 0
        for row in 0..<dhashHeight {
            for column in 0..<(dhashWidth - 1) {
                let left = small[row * dhashWidth + column]
                let right = small[row * dhashWidth + column + 1]
                if left < right {
                    hash |= (1 << UInt64(row * dhashHeight + column))
                }
            }
        }
        return FrameFingerprint(dhash: hash, thumb: thumb)
    }

    /// Mean absolute luminance difference between two thumbnails, normalized to 0...1.
    /// This is the number `CHANGE_THRESHOLD` is compared against.
    public static func changeScore(_ a: FrameFingerprint, _ b: FrameFingerprint) -> Double {
        guard a.thumb.count == b.thumb.count, !a.thumb.isEmpty else { return 1 }
        var total = 0
        for i in 0..<a.thumb.count {
            total += abs(Int(a.thumb[i]) - Int(b.thumb[i]))
        }
        return Double(total) / (Double(a.thumb.count) * 255.0)
    }

    /// Bit distance between two difference hashes — for exact-duplicate detection and later
    /// dedup queries, not for the change threshold.
    public static func hamming(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    // MARK: Internals

    /// Draws `image` into a `width`x`height` 8-bit grayscale context and returns the raw bytes.
    /// Returns all-zero bytes if the context cannot be made, so callers never have to unwrap.
    static func grayscale(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
        let count = width * height
        var pixels = [UInt8](repeating: 0, count: count)
        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width,
                      space: CGColorSpaceCreateDeviceGray(),
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  )
            else { return }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }
}
