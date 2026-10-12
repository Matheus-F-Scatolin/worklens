import Foundation
import GRDB

/// The one `captures` lookup the day's accounting (#320) needs and `CaptureStore` does not have.
///
/// On `Database`, like `CaptureStore+Scheduler`, because the store's connection is private.
public extension Database {
    /// The last row before `date`, whatever it says: the lock, sleep or idle row that may still
    /// hold at midnight. One indexed query.
    func lastCaptureRow(before date: Date) throws -> Capture? {
        try writer.read { db in
            try Capture
                .filter(Column("captured_at") < date)
                .order(Column("captured_at").desc)
                .fetchOne(db)
        }
    }
}
