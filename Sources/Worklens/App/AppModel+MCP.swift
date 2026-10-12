import Foundation
import WorklensCore

/// The link an assistant reads this Mac's days through, watched rather than assumed (#248).
///
/// Before this, `MCPClientConfig.health` was computed in exactly two places: while the Claude
/// card was on screen, and at a shell prompt. So the one failure this feature actually has — the
/// app moves or is reinstalled, and the entry in a client's file now names a binary that is not
/// there — reached the user only if they happened to open that pane. For somebody with no Claude
/// key the link is the whole product, and it broke in silence.
///
/// Three rules, in order of how much damage getting them wrong does:
///
/// 1. **A client that never connected is never told its link broke.** `app_state` remembers
///    which clients have reported `pointsHere`, and a client outside that set never raises
///    anything — a stale entry somebody else's checkout left in the file is not this user's
///    problem. It is a set rather than a flag so that one client going stale is still noticed
///    while the other still points here.
/// 2. **Only `stalePath` raises.** `outOfDate` and `pointsElsewhere` still launch a server that
///    works, and the pane's **Reconnect** is enough for them; `unparseable` is a file Worklens
///    never writes and never will.
/// 3. **No timer work while nothing is connected.** The loop stops itself on an install with no
///    link, and a connect from the pane starts it again.
///
/// The decision itself is `MCPClientConfig.linkState`, in `WorklensCore` and tested there; what
/// is here is the schedule, the `app_state` row and the notice.
extension AppModel {
    /// The `app_state` row naming the clients this install has had a working link to, comma
    /// separated. Which ones, not merely whether: with two clients, one can go stale while the
    /// other still points here, and a flag cannot tell those apart.
    static let mcpEverConnectedKey = "mcp_ever_connected"

    /// How often the link is re-read. Nothing here is urgent: a broken link is noticed at the
    /// next launch, and an app that moves while it is running is rare enough that an hour is a
    /// generous answer rather than a slow one.
    static let mcpHealthInterval: TimeInterval = 3600

    /// Called once from the launch sequence. Idempotent: a second call while the loop is running
    /// changes nothing.
    func startMCPHealthWatch() {
        guard MCPHealthWatch.shared.task == nil else { return }
        MCPHealthWatch.shared.task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard await self.checkMCPLink() else {
                    MCPHealthWatch.shared.task = nil
                    return
                }
                try? await Task.sleep(for: .seconds(AppModel.mcpHealthInterval))
            }
        }
    }

    /// Reads every client's file and raises, clears, or does nothing at all. Returns whether
    /// there is still anything worth watching.
    @discardableResult
    func checkMCPLink() async -> Bool {
        // Not ready is not the same as nothing to watch: the launch call can land before the
        // database is open, and answering false there would stop the loop for the whole session.
        guard let db else { return true }
        let state = AppStateStore(db)
        var everConnected = AppModel.mcpEverConnected(state)
        let plan = mcpPlan
        let clients = MCPClientConfig.Client.allCases
        // Reading two small files is still file I/O, and this runs on every launch.
        let readings = await Task.detached {
            clients.map {
                MCPClientConfig.Reading(
                    client: $0,
                    health: MCPClientConfig.health(
                        entry: MCPClientConfig.read(at: $0.configURL()), expecting: plan
                    )
                )
            }
        }.value

        // Remember anything pointing here before deciding, so a client that connects while the
        // app runs is watched from the next tick rather than the next launch.
        let pointingHere = Set(readings.filter { $0.health == .pointsHere }.map(\.client))
        if !pointingHere.isSubset(of: everConnected) {
            everConnected.formUnion(pointingHere)
            AppModel.setMCPEverConnected(everConnected, state)
        }

        switch MCPClientConfig.linkState(readings, everConnected: everConnected) {
        case .connected:
            clear(.mcpDisconnected)
            return true
        case .broken:
            // The sentence names no path: it reaches the menu, the Activity list and the log.
            raise(.mcpDisconnected)
            return true
        case .nothingConnected:
            // Nothing points here and nothing in that state can ever raise. Stop; a connect from
            // the pane calls `noteMCPConnected` and starts the loop again.
            clear(.mcpDisconnected)
            return false
        }
    }

    /// A client reports `pointsHere`: remember it, drop the problem if one was open, and make
    /// sure something is watching from now on.
    func noteMCPConnected(_ client: MCPClientConfig.Client) {
        clear(.mcpDisconnected)
        defer { startMCPHealthWatch() }
        guard let db else { return }
        let state = AppStateStore(db)
        var set = AppModel.mcpEverConnected(state)
        guard set.insert(client).inserted else { return }
        AppModel.setMCPEverConnected(set, state)
    }

    /// The remembered set, ignoring anything in that row that is not a client this build knows.
    static func mcpEverConnected(_ state: AppStateStore) -> Set<MCPClientConfig.Client> {
        let raw = ((try? state.get(AppModel.mcpEverConnectedKey)) ?? nil) ?? ""
        return Set(raw.split(separator: ",").compactMap { MCPClientConfig.Client(rawValue: String($0)) })
    }

    /// Sorted, so the row does not churn between launches.
    static func setMCPEverConnected(_ clients: Set<MCPClientConfig.Client>, _ state: AppStateStore) {
        try? state.set(
            AppModel.mcpEverConnectedKey, clients.map(\.rawValue).sorted().joined(separator: ","))
    }

    /// The entry this build would write — the same plan the pane and the CLI build, so the health
    /// the watch computes is the health the pane shows.
    private var mcpPlan: MCPClientConfig.Plan {
        let envFile = ProcessInfo.processInfo.environment["WORKLENS_ENV_FILE"].map {
            URL(fileURLWithPath: $0)
        }
        let executable = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "Worklens")
        return MCPClientConfig.plan(executable: executable, envFile: envFile)
    }
}

/// Where the loop lives. `AppModel` is one object for the life of the process (`SingleInstance`),
/// and an extension cannot add a stored property to it, so the handle is held here rather than
/// by editing `AppModel.swift` — which two other issues own this wave.
@MainActor
final class MCPHealthWatch {
    static let shared = MCPHealthWatch()
    var task: Task<Void, Never>?
    private init() {}
}
