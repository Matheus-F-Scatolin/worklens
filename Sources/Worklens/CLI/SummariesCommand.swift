import ArgumentParser
import Foundation
import WorklensCore

struct SummariesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "summaries",
        abstract: "How Worklens summarizes screenshots: Claude Code, Codex or Gemini.",
        subcommands: [SummariesCheckCommand.self]
    )
}

/// Asks each summarizer whether it can work, without summarizing anything: is the command
/// installed, is it signed in with a plan, is the Gemini key set. Costs nothing and sends no
/// screenshot. Never signs anything in: the sign-in steps are printed for the person to run.
struct SummariesCheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Say which summarizers are ready, in the order they are tried. Sends no screenshot."
    )

    func run() async throws {
        let config = try CLIConfig.load()
        let cli = SubscriptionCLIRunner()
        let workspace = SubscriptionWorkspace(dataDir: config.dataDir)
        try? workspace.prepare()
        let checker = SubscriptionStatusChecker(cli: cli, workingDirectory: workspace.emptyDirectory)

        let order = SummaryProviders.effective(config)
        let listed = config.summaryProviders.isEmpty ? "(empty: Gemini alone)" : config.summaryProviders
            .map(\.rawValue).joined(separator: ",")
        print("SUMMARY_PROVIDERS  \(listed)")
        print("tried in order     \(order.isEmpty ? "nothing is set up" : order.map(\.rawValue).joined(separator: ", "))")
        print("")

        for tool in SubscriptionTool.allCases {
            let status = await checker.status(tool)
            let name = DescribeHealth.commandName(tool)
            print(name)
            print("  command          \(status.executable ?? "not found")")
            print("  sign-in          \(Self.loginLine(status))")
            if let expires = status.loginExpiresAt {
                print("  sign-in ends     \(ISO8601DateFormatter().string(from: expires))")
            }
            if tool == .codex, let executable = status.executable {
                let resolver = CodexModelResolver(
                    cli: cli,
                    cacheFile: workspace.emptyDirectory.deletingLastPathComponent()
                        .appendingPathComponent("codex-models.json"),
                    workingDirectory: workspace.emptyDirectory
                )
                let model = await resolver.model(family: config.codexSummaryModel, executable: executable)
                print("  model            \(model ?? "the command's default") (family \(config.codexSummaryModel))")
            } else if tool == .claude {
                print("  model            \(config.claudeSummaryModel)")
            }
            switch status.login {
            case .notInstalled:
                print("  your step        install \(name), then run `\(tool.loginCommand)` in Terminal")
            case .signedOut, .notSubscription:
                print("  your step        run `\(tool.loginCommand)` in Terminal and sign in with your plan")
            case .subscription:
                break
            }
            print("")
        }

        print("Gemini")
        print("  GEMINI_API_KEY   \((config.geminiAPIKey ?? "").isEmpty ? "not set" : "set")")
        print("  model            \(config.describeModel)")
    }

    static func loginLine(_ status: SubscriptionStatus) -> String {
        switch status.login {
        case .notInstalled: return "not installed"
        case .signedOut: return "not signed in"
        case let .notSubscription(method):
            return "signed in with \(method), not a plan; Worklens will not use it"
        case .subscription:
            guard let plan = status.plan else { return "signed in with a plan" }
            return "signed in with a plan (\(plan))"
        }
    }
}
