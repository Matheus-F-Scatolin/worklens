import Foundation
import Testing

@testable import WorklensCore

@Suite("Checkout locator")
struct CheckoutLocatorTests {
    // Compared by `path` throughout: `deletingLastPathComponent()` hands back a directory URL
    // with a trailing slash, which is the same directory and a different `URL` value.
    private let installed = URL(fileURLWithPath: "/Applications/Worklens.app")
    private let inTree = URL(fileURLWithPath: "/Users/x/worklens/build/Worklens.app")
    private let checkout = URL(fileURLWithPath: "/Users/x/worklens")

    /// The whole point of #119: `make install` moves the bundle away from its checkout, and
    /// without the stamp the app has nothing left to look at.
    @Test("an installed bundle finds its checkout through the stamp")
    func stampedPathWins() {
        let root = CheckoutLocator.resolve(
            stampedPath: checkout.path,
            bundleURL: installed,
            isCheckout: { $0.path == self.checkout.path }
        )
        #expect(root?.path == checkout.path)
    }

    @Test("a bundle still in build/ finds its checkout without a stamp")
    func grandparentFallback() {
        let root = CheckoutLocator.resolve(
            stampedPath: nil,
            bundleURL: inTree,
            isCheckout: { $0.path == self.checkout.path }
        )
        #expect(root?.path == checkout.path)
    }

    /// A stamp is a claim about a directory that may have been deleted, renamed or moved since
    /// the build. No update item is a better answer than one that fails mid-replacement.
    @Test("a stamp pointing at a directory that is no longer a checkout falls through")
    func staleStampFallsThroughToTheBundle() {
        let root = CheckoutLocator.resolve(
            stampedPath: "/Users/x/deleted",
            bundleURL: inTree,
            isCheckout: { $0.path == self.checkout.path }
        )
        #expect(root?.path == checkout.path)
    }

    @Test("a copy dragged somewhere else with no stamp has no checkout")
    func nothingToFind() {
        let root = CheckoutLocator.resolve(
            stampedPath: nil,
            bundleURL: installed,
            isCheckout: { $0.path == self.checkout.path }
        )
        #expect(root == nil)
    }

    @Test("a directory is a checkout only with both scripts/update.sh and Package.swift")
    func looksLikeCheckoutWantsBoth() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worklens-checkout-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: tmp.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        #expect(CheckoutLocator.looksLikeCheckout(tmp) == false)

        let script = tmp.appendingPathComponent("scripts/update.sh")
        try "#!/bin/bash\n".write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        // Executable script, no manifest: not yet.
        #expect(CheckoutLocator.looksLikeCheckout(tmp) == false)

        try "// swift-tools-version:6.1\n".write(
            to: tmp.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        #expect(CheckoutLocator.looksLikeCheckout(tmp))
    }
}
