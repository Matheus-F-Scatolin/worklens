import Foundation
import GRDB

/// Two `captures` lookups the scheduler (#6) needs and `CaptureStore` does not have.
///
/// They hang off `Database` rather than `CaptureStore` because that store's connection is
/// private and #5 belongs to another branch this week; when the two land, moving these into
/// `CaptureStore` is a rename.
public extension Database {
    /// The most recent row, whatever its status. Read once at `start()` so the "one row per
    /// idle/lock period" rule survives a restart instead of writing a duplicate skip row.
    func latestCapture() throws -> Capture? {
        try latestCapture(withImageOnly: false)
    }

    /// The most recent row that actually stored a frame — the anchor for the describe heartbeat,
    /// so a restart does not reset the "describe at least every CAPTURE_HEARTBEAT_SECONDS" clock.
    func latestImagedCapture() throws -> Capture? {
        try latestCapture(withImageOnly: true)
    }

    private func latestCapture(withImageOnly: Bool) throws -> Capture? {
        try writer.read { db in
            var request = Capture.order(Column("captured_at").desc)
            if withImageOnly { request = request.filter(Column("image_path") != nil) }
            return try request.fetchOne(db)
        }
    }
}
