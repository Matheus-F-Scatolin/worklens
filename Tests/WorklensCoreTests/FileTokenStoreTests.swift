import Foundation
import Testing

@testable import WorklensCore

@Suite("Google grant in a file")
struct FileTokenStoreTests {
    private func temporaryDirectory() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worklens-file-token-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func tokens(email: String = "you@example.com") -> GoogleAuth.Tokens {
        GoogleAuth.Tokens(
            accessToken: "ya29.access-token",
            refreshToken: "1//refresh-token",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            email: email,
            scope: "calendar.readonly"
        )
    }

    @Test("a grant survives a round trip, and nothing is there before one is written")
    func roundTrip() throws {
        let dir = temporaryDirectory()
        let store = FileTokenStore(dataDir: dir)

        #expect(try store.hasGrant() == false)
        #expect(try store.load() == nil)

        let written = tokens()
        try store.save(written)

        #expect(try store.hasGrant() == true)
        #expect(try store.load() == written)
        #expect(store.path == dir.appendingPathComponent("google-token.json").path)
    }

    @Test("the file is 0600, so no other account on the Mac can read the grant")
    func permissions() throws {
        let dir = temporaryDirectory()
        let store = FileTokenStore(dataDir: dir)
        try store.save(tokens())

        let mode = try FileManager.default.attributesOfItem(atPath: store.path)[.posixPermissions]
        #expect(mode as? Int == 0o600)
    }

    @Test("a refresh overwrites in place, atomically, and leaves no temporary behind")
    func overwrite() throws {
        let dir = temporaryDirectory()
        let store = FileTokenStore(dataDir: dir)
        try store.save(tokens())
        let refreshed = GoogleAuth.Tokens(
            accessToken: "ya29.a-newer-one",
            refreshToken: "1//refresh-token",
            expiresAt: Date(timeIntervalSince1970: 1_800_003_600),
            email: "you@example.com",
            scope: nil
        )
        try store.save(refreshed)

        #expect(try store.load() == refreshed)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(left == ["google-token.json"])
    }

    @Test("a truncated file reads as no grant rather than throwing")
    func corrupt() throws {
        let dir = temporaryDirectory()
        let store = FileTokenStore(dataDir: dir)
        try store.save(tokens())
        try Data("{\"email\":".utf8).write(to: URL(fileURLWithPath: store.path))

        #expect(try store.hasGrant() == true)
        #expect(try store.load() == nil)
    }

    @Test("clear removes the file, and clearing twice is not an error")
    func clear() throws {
        let dir = temporaryDirectory()
        let store = FileTokenStore(dataDir: dir)
        try store.save(tokens())

        try store.clear(email: "you@example.com")
        #expect(try store.hasGrant() == false)
        try store.clear(email: "you@example.com")
    }

    @Test("saving creates DATA_DIR when the first connect happens before anything else")
    func createsDirectory() throws {
        let dir = temporaryDirectory().appendingPathComponent("not-yet-there")
        let store = FileTokenStore(dataDir: dir)
        try store.save(tokens())

        #expect(try store.hasGrant() == true)
    }

    @Test("GOOGLE_TOKEN_STORE picks the store, and the keychain stays the default")
    func configuredStore() throws {
        let cwd = URL(fileURLWithPath: NSTemporaryDirectory())
        let keychain = try Config.load(layers: [[:]], cwd: cwd)
        #expect(keychain.googleTokenStore == .keychain)
        #expect(GoogleAuth.store(for: keychain) is KeychainTokenStore)

        let file = try Config.load(layers: [["GOOGLE_TOKEN_STORE": "file"]], cwd: cwd)
        #expect(file.googleTokenStore == .file)
        #expect(GoogleAuth.store(for: file) is FileTokenStore)
    }
}
