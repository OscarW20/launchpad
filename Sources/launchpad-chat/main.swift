import Foundation
import LaunchpadCore

// Launchpad's chat tools: a small MCP server (stdio, JSON-RPC, one message per line) the app adds to a bot's
// MCP config for each run. Tool calls become lines in the run's actions file, which the app reads and shows.
//
//   launchpad-chat [--actions <file>] [--plan-answer <file>] [--plan-wait <seconds>] [--claims <file>]
//                  [--bot-name <name>] [--bot-id <id>] [--routines <routines.json>] [--routine-target bot:<id>|group:<id>]
//
// Each flag can also come from the environment: LP_ACTIONS_FILE, LP_PLAN_ANSWER_FILE, LP_PLAN_WAIT, LP_CLAIMS_FILE,
// LP_BOT_NAME, LP_BOT_ID, LP_ROUTINES_FILE, LP_ROUTINE_TARGET. See ChatToolsServer in LaunchpadCore.

let config = ChatToolsConfig.from(arguments: Array(CommandLine.arguments.dropFirst()),
                                  environment: ProcessInfo.processInfo.environment)
let server = ChatToolsServer(config: config)
server.serve(readLine: { readLine(strippingNewline: true) }) { line in
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}
