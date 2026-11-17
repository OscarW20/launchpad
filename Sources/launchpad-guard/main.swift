import Foundation
import LaunchpadCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Claude Code PreToolUse hook. Reads the tool call as JSON on stdin.
//
//   launchpad-guard hook <rules.json> [--ask <request base>] [--approvals <folder>]
//     The permission guard (GuardEngine): the bot's own rules, locked skills, Launchpad's files.
//     With --ask, a call that needs your OK shows an approval card and waits for your answer.
//   launchpad-guard --approvals <folder>
//     The older guard: blocks deploys, sends, spending and deletes until you approve in chat.
//
// Exit 0 lets the call go ahead (a JSON decision may be on stdout); exit 2 blocks it, with the reason on stderr.

let args = Array(CommandLine.arguments.dropFirst())

func value(after flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let input = FileHandle.standardInput.readDataToEndOfFile()

if args.first == "hook" {
    let rules = args.count > 1 && !args[1].hasPrefix("--") ? args[1] : nil
    let grants = value(after: "--approvals").map { ApprovalGrants(directory: URL(fileURLWithPath: $0, isDirectory: true)) }
    let parent = getppid()
    let result = GuardHook.run(input: input, rulesPath: rules, askBase: value(after: "--ask"), grants: grants,
                               stillWanted: { getppid() == parent })   // stop waiting if the bot was stopped
    if let out = result.stdout { FileHandle.standardOutput.write(Data((out + "\n").utf8)) }
    if let err = result.stderr { FileHandle.standardError.write(Data((err + "\n").utf8)) }
    exit(result.exitCode)
}

var folder = ApprovalGrants(paths: .default).directory
if let dir = value(after: "--approvals") {
    folder = URL(fileURLWithPath: dir, isDirectory: true)
}
switch GuardDecision.evaluate(hookJSON: input, grants: ApprovalGrants(directory: folder)) {
case .allow:
    exit(0)
case .block(let reason):
    FileHandle.standardError.write(Data((reason + "\n").utf8))
    exit(2)
}
