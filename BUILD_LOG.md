# Build log

## Phase 1: chat with one bot (2026-11-17)

### CLI flags checked before writing the runner

Checked `--help` on **Claude Code 2.1.326** and **codex-cli 0.169.0**, then ran both for real.

**Claude Code** (`claude -p`, prompt on stdin):

| Need | Flag | Checked |
|---|---|---|
| Non-interactive | `-p` / `--print` (reads the prompt from stdin) | ran it |
| Streaming JSON | `--output-format stream-json --verbose` (`--verbose` is required with stream-json) | ran it |
| Token-by-token text | `--include-partial-messages` (`stream_event` / `text_delta`) | ran it |
| New session with a known id | `--session-id <uuid>` | ran it |
| Resume a chat | `--resume <uuid>` (bot remembered a word across runs) | ran it |
| Unknown session | prints `No conversation found with session ID: …`, result `is_error: true`, exit 1 | ran it |
| Model | `--model <alias or name>` | ran it (haiku) |
| Permissions | `--permission-mode default/acceptEdits/bypassPermissions`, `--allowedTools`, `--disallowedTools`, `--dangerously-skip-permissions` | help text |
| MCP (later) | `--mcp-config <file>`, `--strict-mcp-config` | help text |
| Sign in | `claude auth login` | help text |

Events used: `system/init` (session id), `stream_event` text deltas, `assistant` (tool_use blocks),
`user` (tool_result), `result` (success or error, cost). `rate_limit_event` reports plan usage
(utilisation per 5-hour and 7-day window), which phase 6 can use for the sidebar.

**Codex** (`codex exec`, prompt on stdin via `-`):

| Need | Flag | Checked |
|---|---|---|
| Non-interactive | `codex exec … -` (reads stdin) | ran it |
| JSON events | `--json` (JSONL on stdout) | ran it |
| Resume | `codex exec resume --json <thread_id> -` | help text |
| Outside a git repo | `--skip-git-repo-check` | ran it |
| Sandbox | `-c sandbox_mode="read-only"/"workspace-write"`, `--dangerously-bypass-approvals-and-sandbox` (`-s` isn't on `resume`, so `-c` is used for both) | help text |
| Model | `-m <model>` | help text |
| Sign in | `codex login` | help text |

Events used: `thread.started` (thread id), `item.started/completed` for `agent_message`,
`command_execution`, `file_change`, `mcp_tool_call`, `web_search`, `todo_list`; `turn.completed`,
`turn.failed`. Top-level `error` events are retries ("Reconnecting… 2/5") and aren't final on
their own. Codex sends whole messages, not token-by-token text. Not signed in shows up as
`401 Unauthorized`. I couldn't sign in to Codex here, so its happy path is tested against the
documented event shapes plus the real error output, not a live run.

### What was built

- Swift package: `LaunchpadCore` (no UI, builds and tests on Linux) + `Launchpad` (SwiftUI, macOS 14).
- Three columns: sidebar (Chats, Bots, Groups, Skills, Connectors, Settings), chat list with search
  and All / Bots / Groups filters, and the conversation.
- New bot sheet: name, emoji avatar, colour, role, engine, model, permission. Creates
  `bots/<id>/` with bot.json, CLAUDE.md, AGENTS.md, notes.md and workspace/.
- Bot editor: profile, engine, permission, and instructions (written to both CLAUDE.md and AGENTS.md).
- Sending a message runs the engine in the bot's folder and streams the reply: markdown, code blocks
  with Copy, tables, task lists, and a collapsible "N steps" section listing each tool used, with
  input and output.
- Each chat stores its engine session per bot and resumes it. If the engine has lost the session,
  the app says so and starts fresh once, on its own.
- Stop button (and Esc). It sends SIGINT so the engine can save its session, then ends the engine
  and anything it started.
- Plain-English errors with a fix: signed out ("Claude Code needs you to sign in. Click here to open
  Terminal", which runs `claude auth login` or `codex login`), not installed, usage limit,
  network, busy, and unknown (with "Show details").
- Live folder watching: edit a bot.json or CLAUDE.md by hand and the app updates.
- Settings: Launchpad folder, and whether each engine is installed.
- `scripts/make-app.sh` builds `dist/Launchpad.app`. GitHub Actions builds and tests on macOS.

### Decisions

- **Prompt on stdin, not argv**, so a message starting with `-` can't be read as a flag.
- **Claude session id chosen up front** (`--session-id`). It's saved to the chat only after a run
  ends well (or is stopped), so a failed first run (e.g. signed out) doesn't leave a broken session.
- **Permission mapping**:
  - Read only. Claude: only Read/Grep/Glob/WebSearch/WebFetch/TodoWrite allowed, with edits and Bash
    blocked. Codex: `read-only` sandbox.
  - Can edit workspace (default). Claude: `acceptEdits`, which edits files in the bot folder but
    can't run shell commands. Codex: `workspace-write` sandbox, which runs commands with no network.
  - Full access. Claude: `bypassPermissions`. Codex: no sandbox.
  - Claude's "can edit workspace" is stricter than Codex's: no shell. Phase 5 (approval cards)
    is where shell commands get approved per action.
- **The bot runs in its own folder** (not `workspace/`), so the engine picks up CLAUDE.md /
  AGENTS.md and can update notes.md. Instructions tell it to work in `./workspace/`.
- **Folder watching polls** about 20 small files once a second, not FSEvents on the whole tree, so
  big workspaces (node_modules) cost nothing and the same code is testable on Linux.
- **Finding the CLIs**: apps opened from the Dock don't get your shell's PATH, so the app asks your
  login shell for it once, and also checks ~/.local/bin, Homebrew, npm-global, nvm and similar.
- **CLAUDE.md ↔ AGENTS.md**: the most recently edited file wins and is copied to the other.
- Deleting a bot moves its folder to the Trash.

### Tests

47 tests in `LaunchpadCoreTests`, all passing (Linux, Swift 6.2):
parsers against real captured output, command building, error wording, the real runner
against fake `claude`/`codex` scripts (streaming, failure, missing CLI, Stop), bot/chat storage,
CLAUDE.md/AGENTS.md sync, folder watching and markdown.
Plus one opt-in live test that ran against the real Claude Code here: create a bot, ask it to remember a
word, resume, and ask again. It passed.

The SwiftUI target can't be built in this Linux container. CI builds it on macOS (see the
Actions tab).

### Known gaps / next

- Groups, Skills and Connectors pages are placeholders until their phases.
- No app icon yet.
- Codex's success path hasn't been run live (no sign-in in the build container).
