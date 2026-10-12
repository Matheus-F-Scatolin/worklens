import AppKit
import Darwin
import WorklensCore

// A single binary serves two roles: launched from Finder/`open` with no arguments it is the
// menu-bar app; launched with arguments it is the headless CLI. No `@main` anywhere, because
// top-level code in `main.swift` is the entry point. `worklens app` is the app, and so is a plain
// `worklens run` (#15): no subcommand answers to `run`, but aliases and login items may still
// launch the app with it, so it stays routed here.
//
// Both GUI verbs are answered here rather than from a subcommand's `run()` on purpose: an
// NSApplication has to come up from the top level of the process, which is the same reason the
// no-argument branch below has always been here.
//
// The no-argument case is ambiguous, and `make install` (#119) made it matter: LaunchServices
// starts an app with no arguments at all, and so does a person typing `worklens` at a prompt to
// see what it does. Answering "start a second menu-bar app" is right for the first and wrong for
// the second, so the distinguisher is the terminal, not the argument count — a GUI launch has no
// tty on any of its standard descriptors.
let args = Array(CommandLine.arguments.dropFirst())
let launchedFromATerminal = isatty(STDOUT_FILENO) == 1 || isatty(STDERR_FILENO) == 1
let wantsTheApp = args == ["app"] || args == ["run"] || (args.isEmpty && !launchedFromATerminal)

if wantsTheApp || args.first?.hasPrefix("-psn") == true {
    // Only the new, explicit verb refuses: `run` and the no-argument launch keep behaving exactly
    // as they did, so nobody's alias or login item changes meaning under them.
    if args == ["app"], let refusal = AppCommand.refusal {
        FileHandle.standardError.write(Data(("error: " + refusal.message + "\n").utf8))
        exit(refusal.exitCode)
    }
    WorklensApp.main()
} else {
    CLIEntryPoint.noteIfUnbundled()
    await CLIEntryPoint.run(args.isEmpty ? ["--help"] : args)
}
