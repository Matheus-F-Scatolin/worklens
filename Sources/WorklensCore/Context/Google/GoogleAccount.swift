import Foundation

/// Where the connected Google address is remembered *outside* the Keychain.
///
/// The address is not a secret, and `app_state` can be read without decrypting the grant. That
/// matters because Keychain access is tied to the reading binary's code signature: after an
/// ad-hoc `make sign` the first decrypt of `dev.worklens.google` raises "Worklens wants to use
/// your confidential information" and blocks until someone clicks it (#36). Status surfaces name
/// the account from here instead, so only paths that actually need the token ever prompt.
public protocol GoogleAccountRecord: Sendable {
    /// The address of the last account connected on this machine, or nil if none was recorded.
    func address() -> String?
    func remember(_ address: String)
    func forget()
}

/// The production record: one row in `app_state`, under `google_account_email`.
///
/// The database is opened lazily and cached, so constructing a `GoogleAuth` still touches
/// neither the disk nor the Keychain.
public final class AppStateGoogleAccountRecord: GoogleAccountRecord, @unchecked Sendable {
    public static let key = "google_account_email"

    private let dataDir: URL
    private let lock = NSLock()
    private var opened: Database?

    public init(dataDir: URL) { self.dataDir = dataDir }

    private var state: AppStateStore? {
        lock.withLock {
            if let opened { return AppStateStore(opened) }
            guard let db = try? Database(dataDir: dataDir) else { return nil }
            opened = db
            return AppStateStore(db)
        }
    }

    public func address() -> String? {
        guard let value = (try? state?.get(Self.key)) ?? nil, !value.isEmpty else { return nil }
        return value
    }

    public func remember(_ address: String) {
        do {
            try state?.set(Self.key, address)
        } catch {
            // Not worth failing a connect over: the grant is stored, status just has less to say.
            Log.net.error("could not record the connected Google account: \(error)")
        }
    }

    public func forget() { try? state?.delete(Self.key) }
}

/// A dictionary-backed record, so tests can exercise the status paths without a database.
public final class InMemoryGoogleAccountRecord: GoogleAccountRecord, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    public init(_ address: String? = nil) { self.stored = address }

    public func address() -> String? { lock.withLock { stored } }
    public func remember(_ address: String) { lock.withLock { stored = address } }
    public func forget() { lock.withLock { stored = nil } }
}

/// What the status surfaces say about a Google grant whose address was never recorded (#36).
///
/// Such a grant predates #36. Decrypting the item would answer the question and may prompt, so
/// the honest answer is that we did not look; one reconnect records the address and the question
/// goes away.
public enum GoogleGrantStatus {
    /// The line every surface uses for a stored grant whose address was never recorded.
    ///
    /// #139 reworded it. The old sentence — "stored (not read; a rebuilt binary would prompt)" —
    /// described the implementation of a decision the reader had not made and offered them
    /// nothing to do; the distinction it protects is real (the address genuinely was not read),
    /// so it survives as a state with a remedy attached.
    public static let addressUnknownNote = "Connected \u{b7} account unknown: Reconnect to confirm"
}
