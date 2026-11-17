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

---

## Phases 2–6 (2026-11-17)

You said to carry on through all the remaining phases, so they were built in one go.

### More CLI facts checked live (Claude Code 2.1.326, codex-cli 0.169)

- **Skills:** Claude Code finds skills in `./.claude/skills/<name>/SKILL.md` in the bot's folder, **including symlinks**
  (checked: a symlinked skill was found and followed). Codex looks in `.agents/skills` / `.codex/skills`
  (seen in the binary; `codex features list` shows skills on). Launchpad links each skill into all three.
- **Approvals can be enforced:** a `PreToolUse` hook passed with `--settings '{"hooks":…}'` runs **even in
  bypassPermissions mode**. Exit code 2 blocks the tool and the bot sees why. Live test with the real guard binary:
  the bot tried `rm`, was blocked, replied with `[[approve: …]]`; after recording the approval it ran and the file was gone.
- **MCP secrets stay out of files:** `--mcp-config '{"mcpServers":{…"env":{"TOK":"${LP_SECRET}"}}}'` expands
  `${VAR}` from the process environment (checked with a tiny MCP server: it received the secret). Codex: `-c mcp_servers.<id>.…`
  with `env_vars` / `bearer_token_env_var`, also environment-only.
- `--append-system-prompt`, `--add-dir`, `--strict-mcp-config`, `--no-session-persistence` (Claude);
  `--ephemeral`, `-c sandbox_workspace_write.writable_roots=[…]` (Codex).
- The `rate_limit_event` gives Claude plan usage (`unifiedWindows.five_hour/seven_day.utilization`). Codex's
  `turn.completed` gives token counts only.

### Phase 2: Skills
- Skills page: list, editor with Edit / Preview / Side by side, Duplicate, Delete, Show in Finder.
- Starter skills seeded once: new-project, deploy, code-review, write-spec (deleting one sticks).
- Give a skill to a bot (bot editor) or a group (group editor, or the "Give to" chips on a skill). Group skills reach every
  member. Skills are symlinked into each bot's `.claude/skills`, `.agents/skills` and `.codex/skills`; real folders a
  bot made itself are never touched.
- Teach a skill from a chat (header button or right-click a chat): the chat's engine writes a SKILL.md draft from the
  transcript in a no-session run, then you edit and save it.

### Phase 3: Groups
- Create/edit groups: members, lead, rules, hand-off limit (default 3), group skills and connectors.
  Each group has `SUMMARY.md` (lead keeps it) and `workspace/` (shared project folder, added to every member's run).
- Flow (`GroupOrchestrator`, fully tested with a scripted fake team):
  lead first → members in @mention order, one at a time, each seeing new group messages → `[parallel]` line from the lead
  runs them at once → members can @mention each other → lead reviews and either hands off again or wraps up with no
  mentions. Each hand-off counts. Over the limit, the group pauses with a "Keep going" button.
- Ask everyone: members answer in parallel with a short view, then the lead sums up.
- Each bot keeps its own engine session per group chat and is sent only what's new since its last turn.

### Phase 4: Hire
- Templates: Lead, Planner, Designer, Frontend, Backend (Supabase, RLS always on), Tester (Playwright),
  Reviewer (Codex, read-only, second opinion), Shipper (Vercel, deploy skill).
- Dev team: all eight plus `#build-and-ship` with Lead as lead, team rules, and Graphify as a group skill.
  Re-running it reuses what's there.
- Builders (Frontend, Backend, Tester, Shipper) are Full access so they can run npm, tests and Vercel; the approval
  guard still stops deploys, pushes, sends, spending and deletes.

### Phase 5: Connectors and safety
- Connectors page: add MCP servers by URL or command (+ args). Optional API token and secret variables go to the
  **Keychain** (service "Launchpad"); `connectors.json` only has names. Sign-in buttons open Terminal with Claude Code's
  or Codex's own MCP login flow.
- Turn connectors on per bot or per group. Bots get **only** their connectors (`--strict-mcp-config`).
- Permission levels as in phase 1; default "Can edit its workspace".
- Approval cards: every bot is told to ask with `[[approve: …]]`; the card shows Approve / Decline and the bot waits.
  For Claude Code bots it's enforced by the `launchpad-guard` hook (a second small executable shipped inside the app):
  deploys (vercel, netlify, git push, supabase db push, npm publish…), sends (POST requests, gh pr create, mail…),
  spending (domain buys, Stripe creates…) and deletes (rm, git reset --hard, DROP TABLE…) are blocked until you approve.
  Risky-looking MCP tools too (send_*, delete_*, deploy_*, pay…). An approval lasts 15 minutes for that bot's session.
- Codex has no equivalent hook in `exec` mode, so Codex bots rely on the instruction plus their sandbox.

### Phase 6: Routines and usage
- Routines: message a bot or group at a time of day (optionally weekdays only), every N minutes/hours, or when a new
  file appears in a folder (the file paths are added to the message). Run while the app is open; a missed daily one
  runs once later that day. Each routine posts into its own chat. Stored in `routines.json`.
- Sidebar usage: Claude 5-hour and weekly usage bars (from the CLI's rate-limit events) and ChatGPT tokens today
  (from Codex's turn usage). Stored in `.launchpad/usage.json`.
- Voice input (optional) is not built yet.

### Graphify (your request)
- Skills page → + → **Add Graphify**. If `graphify` isn't installed, Terminal opens with
  `uv tool install graphifyy` (or pipx). Otherwise Launchpad runs `graphify install --project` in a scratch folder and
  imports **only its official skill** (SKILL.md + references) into the library. Its always-on hooks and CLAUDE.md
  section are left out so they don't clash with each bot's own instructions and the approval guard.
- The Dev team's `#build-and-ship` group has Graphify as a group skill, and the team rules say to query the graph instead
  of grepping. It switches on as soon as the skill is in the library.
- Not added: Graphify's MCP server (`graphify-mcp <graph.json>`), because it needs a fixed graph path per project.
  You can add it as a connector per project if wanted.
- Checked with the real Graphify (pip package `graphifyy`): the import works.

### Tests
94 tests (plus 2 opt-in live ones). New: group flow (order, history, parallel, member hand-offs, limit, approvals,
failures, Ask everyone), skills (front matter, seeding, linking, teach), approvals (parsing, risky commands and MCP tools,
guard and grants), connectors (Claude JSON, Codex flags, Keychain environment, no secrets on disk or argv), run options,
usage, routines (schedules, weekdays, catch-up, new files), Hire / Dev team, Graphify import.
