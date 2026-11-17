import Foundation
import LaunchpadCore

// Claude Code PreToolUse hook. Reads the tool call as JSON on stdin.
// Exit 0 lets it run; exit 2 blocks it and tells the bot to ask for approval first.
// Usage: launchpad-guard --approvals <folder>

let args = CommandLine.arguments
var folder = ApprovalGrants(paths: .default).directory
if let i = args.firstIndex(of: "--approvals"), i + 1 < args.count {
    folder = URL(fileURLWithPath: args[i + 1], isDirectory: true)
}

let input = FileHandle.standardInput.readDataToEndOfFile()
switch GuardDecision.evaluate(hookJSON: input, grants: ApprovalGrants(directory: folder)) {
case .allow:
    exit(0)
case .block(let reason):
    FileHandle.standardError.write(Data((reason + "\n").utf8))
    exit(2)
}
