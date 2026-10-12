import Foundation
import Network

/// The one-shot `http://127.0.0.1:<port>/callback` listener the OAuth flow redirects back to.
///
/// A loopback listener rather than a custom URL scheme because that is what Google's "Desktop
/// app" client type expects, and because it needs no Info.plist entry — the CLI and the bundled
/// app behave identically.
///
/// It answers exactly one request and stops. The port is whatever the OS hands out, so nothing
/// has to be reserved, and the socket is bound to 127.0.0.1 so nothing off this machine can
/// reach it.
public actor LoopbackReceiver {
    public struct Callback: Sendable, Equatable {
        public var code: String?
        public var state: String?
        /// `access_denied` when the user clicks Cancel on the consent screen.
        public var error: String?
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case couldNotListen(String)
        case timedOut(seconds: Int)
        case badRequest
        /// The user pressed Cancel while the listener was still waiting (#139).
        case cancelled

        public var description: String {
            switch self {
            case let .couldNotListen(detail): return "could not open the loopback listener: \(detail)"
            case let .timedOut(seconds):
                return "Google did not come back in \(LoopbackReceiver.spell(seconds: seconds))."
            case .badRequest: return "the browser sent something that was not an OAuth callback"
            case .cancelled: return "You stopped connecting Google. Nothing was stored."
            }
        }
    }

    /// Five minutes, not one (#139). A first consent is a sign-in, a project picker, the
    /// "Google hasn't verified this app" interstitial and two scope checkboxes; a minute is
    /// shorter than that, and a consent finished at second 61 used to land on a dead port.
    /// The CLI's `--timeout` defaults to this too, so both front ends wait the same.
    public static let defaultTimeout: TimeInterval = 300

    /// `5 minutes` / `90 seconds` — what the timeout sentence calls the window it gave you.
    static func spell(seconds: Int) -> String {
        guard seconds >= 60, seconds % 60 == 0 else { return "\(seconds) seconds" }
        let minutes = seconds / 60
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
    public static let path = "/callback"

    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.worklens.oauth-loopback")
    private var finished = false
    private var started = false
    private var waiter: CheckedContinuation<Callback, any Error>?
    /// A callback that arrived before anyone called `wait()`. Without this a fast browser could
    /// answer between `start()` and `wait()` and the result would be dropped on the floor.
    private var pending: Result<Callback, any Error>?

    public init() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Loopback only: this socket exists for one redirect from the user's own browser.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw Failure.couldNotListen(error.localizedDescription)
        }
    }

    /// Starts listening and returns the redirect URI to hand to Google. Idempotent: calling it
    /// twice hands back the same URI rather than re-arming the socket.
    public func start() async throws -> String {
        if started, let port = listener.port {
            return "http://127.0.0.1:\(port.rawValue)\(LoopbackReceiver.path)"
        }
        started = true
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .global())
            Task { await self?.read(connection) }
        }
        listener.start(queue: queue)

        // `listener.port` is nil until the state machine reaches .ready.
        for _ in 0..<200 {
            if listener.state == .ready, let port = listener.port {
                return "http://127.0.0.1:\(port.rawValue)\(LoopbackReceiver.path)"
            }
            if case let .failed(error) = listener.state {
                throw Failure.couldNotListen(error.localizedDescription)
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure.couldNotListen("the listener never became ready")
    }

    /// Waits for the browser to come back, or gives up.
    public func wait(timeout: TimeInterval = LoopbackReceiver.defaultTimeout) async throws -> Callback {
        if let pending { return try pending.get() }
        let deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.fail(with: Failure.timedOut(seconds: Int(timeout)))
        }
        defer { deadline.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
        }
    }

    public func stop() {
        listener.cancel()
    }

    /// Give up on the user's behalf: the Cancel button in Settings, or `GoogleAuth.cancelConnect`.
    /// Resumes whoever is inside `wait` rather than only closing the socket, which would leave the
    /// flow suspended until the timeout it was told not to wait for.
    public func cancel() {
        finish(with: .failure(Failure.cancelled))
    }

    // MARK: Internals

    private func read(_ connection: NWConnection) {
        // A GET request line and its headers arrive in one segment in every browser worth
        // supporting; there is no body to wait for.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return }
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            Task { await self.handle(text, on: connection) }
        }
    }

    private func handle(_ request: String, on connection: NWConnection) {
        guard !finished else {
            connection.cancel()
            return
        }
        let callback = LoopbackReceiver.parse(request)
        let page = LoopbackReceiver.page(for: callback)
        let response = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(page.utf8.count)\r
            Connection: close\r
            \r
            \(page)
            """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })

        guard let callback else {
            finish(with: .failure(Failure.badRequest))
            return
        }
        finish(with: .success(callback))
    }

    private func fail(with error: any Error) {
        finish(with: .failure(error))
    }

    private func finish(with result: Result<Callback, any Error>) {
        guard !finished else { return }
        finished = true
        listener.cancel()
        guard let continuation = waiter else {
            pending = result
            return
        }
        waiter = nil
        continuation.resume(with: result)
    }

    // MARK: Parsing (pure)

    /// Pulls `code`, `state` and `error` out of a raw HTTP request. Nil when the request is not
    /// a GET of the callback path at all.
    public static func parse(_ request: String) -> Callback? {
        guard let line = request.split(separator: "\r\n", omittingEmptySubsequences: false).first
            ?? request.split(separator: "\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }

        // The request target is a path, so give it a host to be parsed against.
        guard let components = URLComponents(string: "http://127.0.0.1\(parts[1])"),
              components.path == path else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value?.nonEmpty
        }
        return Callback(code: value("code"), state: value("state"), error: value("error"))
    }

    // MARK: The page the browser lands on

    /// What the tab says when the redirect arrives. Three sentences, one template (#139).
    ///
    /// The old page was a bare `<p>` in an inline font: no name on it, no dark mode, and nothing
    /// to tell "Worklens has your grant" from "some other program answered this port". This is
    /// the last thing the connect flow shows, and in a browser theme it used to be a white flash
    /// with a line of text on it.
    static func page(for callback: Callback?) -> String {
        if let error = callback?.error {
            return page(
                title: "Not connected",
                message: "Authorization was declined (\(error)). Nothing was stored. "
                    + "You can close this tab and try again from Worklens."
            )
        }
        if callback?.code != nil {
            return page(
                title: "Worklens is connected",
                message: "You can close this tab: Worklens is finishing up on your Mac."
            )
        }
        return page(
            title: "That was not a Google callback",
            message: "Something else answered this address. Nothing was stored. You can close "
                + "this tab and try again from Worklens."
        )
    }

    /// The themed shell. No network fonts, no images, no script: one file, served once, from a
    /// socket that closes straight after it.
    static func page(title: String, message: String) -> String {
        """
        <!doctype html><html lang="en"><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Worklens</title>
        <style>
          :root { color-scheme: light dark; --ink: #1c1c1e; --dim: #6b6b70; --card: #ffffff; --bg: #f5f5f7; }
          @media (prefers-color-scheme: dark) {
            :root { --ink: #f2f2f7; --dim: #9b9ba1; --card: #1c1c1e; --bg: #101012; }
          }
          body { margin: 0; min-height: 100vh; display: flex; align-items: center;
                 justify-content: center; background: var(--bg); color: var(--ink);
                 font: 16px/1.5 -apple-system, system-ui, sans-serif; }
          main { background: var(--card); padding: 2.5rem 2.75rem; border-radius: 14px;
                 max-width: 30rem; box-shadow: 0 1px 3px rgba(0,0,0,.12); }
          .mark { font-size: .8rem; letter-spacing: .12em; text-transform: uppercase;
                  color: var(--dim); margin: 0 0 .75rem; }
          h1 { font-size: 1.35rem; margin: 0 0 .5rem; }
          p { margin: 0; color: var(--dim); }
        </style>
        <body><main>
        <p class="mark">Worklens</p>
        <h1>\(title)</h1>
        <p>\(message)</p>
        </main></body></html>
        """
    }
}
