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

---

## Marketplace catalog (2026-11-17)

Ported the catalog data of an earlier app of mine into `LaunchpadCore` as plain Swift data, so the Marketplace UI
(Apps / Skills / Roles / Teams) only has to render it. No UI changes in this phase.

### What was built
- **Roles** (`CatalogRoles.swift`, `Hire.swift`): 27 new `HireTemplate`s plus the existing 8 dev-team ones = 35, in 12
  departments (`HireCatalog.categories`). Old pun names were replaced with plain job names, an emoji and a `BotPalette`
  colour. `HireTemplate` gained `category` and `suggestedApps` (both defaulted). Six old roles were folded into the
  dev team instead of duplicated: Product Manager → Planner, Product Designer → Designer, Web Developer → Frontend,
  Code Reviewer → Reviewer, QA Engineer → Tester, DevOps Engineer → Shipper (their duties and skills were merged in).
- **Team packs** (`TeamPacks.swift`): Dev team (`#build-and-ship`), Launch team (`#launch-crew`), Content team
  (`#content-studio`), Engineering team (`#engineering`), Back office (`#back-office`), each with a lead and rules.
  `Hiring.hireTeam(_:)` hires the roles (reusing bots with the same id), creates the group, and on a re-run only
  re-hires deleted bots and puts missing members back. `hireDevTeam()` now calls it.
- **Skills** (`CatalogSkills.swift`): 41 catalog skills = the 4 starters (same text as `StarterSkills`) + 37 more.
  The old catalog's `code-review` is the existing starter. `SkillStore.install(_:)` writes SKILL.md;
  `installIfMissing(_:)` keeps your edits.
- **Apps** (`ConnectorCatalog.swift`): 40 `ConnectorPreset`s in 7 categories. `ConnectorStore.install(_:settings:)`
  creates a connector with id = preset id (re-installing refreshes it in place); `ConnectorStore.storeSecrets`
  puts typed secret values in the secret store (Keychain in the app).
- **Logos**: 51 image files in `Sources/Launchpad/Resources/Logos`, bundled with `.copy("Resources/Logos")`.

### Decisions
- **Role id = slug of its name**, because `BotStore.create` makes the bot id from the name; "already hired?" checks
  and team packs rely on it (a test enforces it).
- **`HireCatalog.all` still means the 8 dev-team templates** because the current Hire page and Dev team card use it.
  The full list is `HireCatalog.roles`.
- **Hiring a role installs the catalog skills it uses** if they're missing (so a hired bot isn't missing its skills),
  and turns on suggested connectors **only if already installed**. It never installs a connector or asks for secrets.
- **Hosted apps are native `.http` connectors** (no mcp-remote) and sign in with the engines' own MCP login. Hosts that
  only speak SSE (Asana, monday.com, Intercom, Webflow, PayPal, Square) stay on `npx -y mcp-remote <url>` as stdio,
  since the http connector type is streamable HTTP only. Jira & Confluence moved to Atlassian's v2 `/mcp` endpoint.
- **GitHub** uses GitHub's hosted server (`https://api.githubcopilot.com/mcp/`) with a personal access token as a
  Keychain bearer token, instead of the deprecated npm package.
- **No secrets in args**: Supabase reads `SUPABASE_ACCESS_TOKEN` from the environment; Postgres's connection string
  (it holds a password) goes in through `sh -c 'exec npx … "$DATABASE_URL"'`. Non-secret paths (SQLite file, folder
  for "Folder access") are `settings` filled into args at install.
- Dropped: the old app's own illustrator app, and its "shared folder" wording (the filesystem preset now asks for a folder).

### Tests
106 tests (plus 2 opt-in live ones), all passing on Linux. New `CatalogTests` (12): counts and unique ids, roles well
formed (id = slug(name), palette colour, known skills/apps, notes/approval/secret rules in the text), team packs
reference real roles, presets well formed (no secret placeholders in args), every logo file exists, no old-brand or
dog wording anywhere, installing every skill gives a parseable SKILL.md, installing every app gives a connector that
round-trips and builds Claude/Codex config, secrets stay out of connectors.json, hiring a role, and hiring every team
pack twice is idempotent (and repairs a deleted member).

### Known gaps / next
- Docs URLs and the SSE/v2 endpoints were taken from the vendors' published docs as I knew them, not re-checked live here.

### Phase 7: Memory (ported from an earlier app's memory system)
- **MEMORY.md** replaces notes.md as each bot's memory: short `- ` lines under topic headings (Preferences, Decisions,
  People, Projects, How I work, Notes). New bots get a MEMORY.md starter; the default instructions, Hire templates and
  Launchpad's rules (`LaunchpadProtocol`) point bots at it. `MemoryStore.importNotesIfNeeded(bot)` moves an existing
  notes.md in once (under `## From notes.md`; the empty starter adds nothing), keeps the original in
  `.launchpad/memory/bots/<id>/notes-imported.md`, and rewrites `./notes.md` → `./MEMORY.md` in CLAUDE.md/AGENTS.md.
- **MemoryBook** (pure): parse/write topics, merge facts (duplicates skipped by normalised word overlap, a fact that
  extends an old line replaces it), a 12 KB cap that only limits a review's own growth (oldest review-topic lines are
  folded into "Earlier: …" lines; your intro and own headings are never touched), secret redaction/`containsSecret`
  (keys, tokens, JWTs, cards, "password is …", logins), tolerant JSON parsing of the model's reply, and
  `applyChanges` (re-applies a change onto a newer file: used by Undo and by the editor's Save).
- **Never overwrite what we can't read**: a MEMORY.md that isn't UTF-8 (or UTF-16 with a BOM) is reported
  `.unreadable` and no review, edit or import writes to it.
- **Versions**: every app write keeps the version before it (and what it wrote) in `.launchpad/memory/bots/<id>/history`
  (10 kept, plus any a live "Memory updated" notice points at), outside the bot's folder so bots don't see them.
  Undo for one review takes back just its lines; "Undo last change" walks back one app change at a time; both keep
  lines the bot wrote itself since. Reviews are logged in `.launchpad/memory/updates.json`; the update id doubles as the
  id of the chat notice, so `Models.swift` needed no new field.
- **Background review**: `MemoryReviewSchedule` is a pure value (clock passed in): a chat is due 10 quiet minutes after
  its last activity, or straight away after `requestPass` (compact / new thread); one pass at a time; 8 passes per bot
  per day (local day); after an engine failure that bot backs off 30 min, doubling to 8 h; a broken-JSON reply retries
  once, then counts as reviewed; first review of an old chat only looks at the last day; less than 40 characters of your
  own writing costs no model call. `MemoryReviewer` saves it to `.launchpad/memory/review.json`, runs the pass via an
  injected engine (`MemoryReviewer.engine(using: EngineRunner)` in the app, a fake in tests) and applies it.
- **The pass**: Claude bots use `haiku` with `--tools ""` and `--strict-mcp-config` (no connectors); Codex bots use
  their own model with `-c model_reasoning_effort="low"`, read-only sandbox. No session kept, scratch folder, transcript
  redacted before it's cut (10 k chars, newest kept), at most 8 facts.
- **Shared files changed** (kept minimal): `RunOptions` gained `quiet` and `reasoningEffort` (EngineCommand.swift);
  `LaunchpadPaths` gained `memoryMD` and `memoryData`; BotStore's `Instructions` (`memoryTemplate`,
  `pointingAtMemory`, MEMORY.md wording), Hire's and LaunchpadProtocol's memory line.
- Not ported: a "Learn from chats" field on `Bot` (kept as a per-bot switch in review.json instead, so bot.json is
  unchanged), local-model engines (Launchpad has none), and a global MCP opt-out for Codex (its exec mode has no
  switch; the pass is read-only there).
- Tests: 59 new (153 total, 2 opt-in live skipped): merge, redaction, size cap (including 1 MB files), versions,
  encodings, Undo, editor save/add/edit/delete, notes import, schedule (idle, budget, back-off, one at a time,
  persistence), the run flags, and the reviewer end to end with a fake engine and clock.
- The macOS app still has to wire it in (AppModel timer, notices with Undo, a memory section in the bot editor).

### Phase 7: Safety core (permissions, guard, sandbox, undo)
Core only (`Sources/LaunchpadCore/Guard`, `Sources/LaunchpadCore/Safety`); the app's UI and wiring come next.

- **Permissions per bot** (`BotRules`, saved in bot.json as `rules`): six categories, each Ask / Allow / Never:
  send or post, delete, spend, change code or shared systems, commands outside its folder, use your Mac.
  Defaults: Ask for all but "commands outside its folder" (Allow). "Always allow" is per category and tool, never for
  the Terminal, and Never always wins. Each bot can add its own "change" commands (regular expressions), replacing
  hard-coded company tools. `PermissionLevel` stays: it still sets Claude's permission mode and Codex's sandbox.
- **The guard** (`ShellParser`, `GuardEngine`, `GuardHook`): reads shell lines properly (splits on ; & && | ||, looks
  inside $( ) and backticks, unwraps env / sudo / xargs / nohup / bash -c / eval, follows cd), finds delete targets
  (rm, find -delete / -exec rm, rsync --delete, git clean, code that deletes in python/node/ruby/perl/osascript),
  paths outside the bot's folders, and sorts MCP tools by their verbs. Deletes inside the bot's own folder are free
  (undo covers them). Locked skills, Launchpad's data folder (rules, answers, grants, snapshots, skill locks) and every
  Claude Code settings file can never be written, in any spelling. It fails closed: unreadable rules or input mean no.
  Launchpad's old "deploy" kind is now part of "change".
- **Approval handshake**: the hook now waits for your answer (Biscuit Bots' design) instead of blocking and asking the
  bot to post `[[approve: …]]`. It writes `.launchpad/requests/<chat>-<run>.approval-<id>.json`, the app shows an
  Approve / Decline / Always allow card and writes `.launchpad/answers/<id>.answer`, and the tool call goes ahead
  without the bot ending its turn. Answers live where no bot can write, so a bot can't approve itself. Up to 570 s;
  a timeout or a stopped bot leaves an `.expired` marker. The older chat flow still works: with no `--ask`, the hook
  blocks with the `[[approve: …]]` instruction, and a 15-minute session grant lets Ask actions through.
  Hook settings: matcher "*", timeout 600, `disableAllHooks: false`, and `"sandbox":{"enabled":false}` under our sandbox.
  `launchpad-guard --approvals <dir>` (the old Bash/MCP-only guard) is unchanged.
- **Rules file** at `.launchpad/rules/<bot-id>.json`, outside the bot's folder, 0444 in a 0555 folder between writes.
- **Sandbox** (`BotSandbox`): an SBPL profile for `sandbox-exec` that protects the app bundle, `.launchpad` (except
  `requests/` and `scratch/`) and Claude settings files; locked down adds no network except localhost, no lsopen or
  Apple Events, no shell profiles / LaunchAgents / cron. `RunOptions.sandboxProfile` → `EngineInvocation.launch(executable:)`
  wraps the engine. Codex is wrapped only when it runs without its own sandbox (they can't nest).
- **Codex mapping**: full access with commands-outside Ask/Never or delete Never → workspace-write (network on);
  locked down → workspace-write, no network. The rest goes in its instructions (`BotRules.codexNote`).
- **Site gateway** (`SiteGateway`): a tiny proxy on 127.0.0.1 so locked-down bots can reach their engine and listed
  sites (CONNECT tunnels for https, forwarding for http, per-run token). Host names only; no inspection or logging.
- **Undo** (`Snapshots`): a private git store per bot (`.launchpad/snapshots/<bot-id>.git`, work tree = bot folder),
  snapshot before a reply, list changed files after, undo restores changed and deleted files and removes new ones.
  Instructions, notes.md, bot.json, engine folders and build output are left out.
- **Secrets**: `SecretStore.read(_:)` returns found / missing / failed; existing stores get a default.

Tests: 139 (plus 2 opt-in live ones). The 186 Biscuit Bots guard self-checks are now XCTest cases (`GuardEngineTests`),
with Biscuit-only ones swapped for generic ones; plus the hook and handshake end to end, rules file, settings JSON, run
options, Codex mapping, sandbox profiles (kernel test on macOS only), snapshots with real git, secrets and the gateway.

### Phase 8: Chat tools and chat features (ported from an earlier app)
Core only (`Sources/LaunchpadCore/Chat`, new executable `launchpad-chat`); the macOS app wires it in next.

- **`launchpad-chat`** MCP server (stdio JSON-RPC; logic in `ChatToolsServer` so it's tested in-process). Tools:
  create_routine (checked with `RoutineRequests`, target fixed to the chat's bot or group), list_routines, ask_user,
  share_plan (waits for Start / Cancel / your words; with a countdown, silence means start; otherwise 570 s then "don't
  start"), react, send_gif, start_poll, vote, use_app / done_with_app (shared claims, 15 min expiry, `flock`).
  Settings come as flags (`--actions … --routine-target …`) or `LP_*` variables; `ChatToolsRun.connector(executable:)`
  passes them as flags, so it goes through `MCPConfig` like any stdio connector and needs no Runner changes.
  `ChatToolsSetup.allowingChatTools` adds `mcp__launchpad_chat` to Claude's `--allowedTools`.
- **Files**: `.launchpad/requests/chat/<run>.actions.jsonl` (one `ChatAction` per line; `requests/` is writable from
  the sandbox), plan answers in `.launchpad/answers/chat/<run>.plan` (app only, so a bot can't start its own plan),
  claims in `.launchpad/scratch/app-claims.json`. `ChatActionReader` tails the file during a run;
  `ChatActionApplier` turns actions into changed messages, reply extras (GIF, poll, plan, questions), GIF searches and
  routines. `ChatTokens` keeps the text fallback (`[react: 🎉]`, `[gif: …]`, `[poll: Q | A | B]`, `[vote: 2]`).
  The legacy guard (`RiskClassifier`) no longer asks about `mcp__launchpad_chat__*`; the permission guard needs
  `trustedServers: ["launchpad_chat"]`.
- **Chat features**: `ChatMessage` gained optional `reactions`, `pinned`, `saved`, `edits` (history), `deleted`,
  `attachments`, `forwardedFrom`, `gif`, `poll`, `plan`, `questions` (old JSONL still decodes). `ChatOps` does
  reactions, pin, save, edit, delete (tombstone), forward, polls, plan and question answers; `ChatStore.update` saves
  by appending (latest wins). `GiphySearch` (key `giphy.API_KEY` in the Keychain) builds the URL and parses replies.
  `TextPacing` splits short replies into texts. To-do lists are left to the runners work (no `todoList` field).
- **Collab**: `ActivityFeed`; team notes in `~/Launchpad/Shared/TEAM.md` (one page for every bot, decided over
  per-group files because groups already have SUMMARY.md); `DirectHandOff` (`@id: …` lines in a 1:1 chat, answer goes
  back to the chat's bot, hop limit); `ReviewRequest`; `Huddle` (a message, then `askEveryone()`).
- **Drafter** (`BotDrafter`): name, role, instructions, emoji and a `BotPalette` colour from one line, via
  `EngineCommand.oneShot`. **FileMentions** / **StepLabel**, **Attachments** (copy into `workspace/Inbox`, "name 2.ext"),
  **SavedPromptsStore** (`.launchpad/saved-prompts.json`), **ChatExport** (Markdown), **QuickSearch** (⌘K ranking).
- Not ported: stickers, phone hang-ups, link previews (UI), image drop decoding (AppKit), per-bot plan wait (a `Bot`
  field; an app setting for now).
- Tests: 45 new (316 total, 2 opt-in live skipped): JSON-RPC handshake and every tool in-process, plan wait with a
  fake clock, claims, routines, config, reader, applier, the guard exemption, and the built binary run once with a
  scripted stdin.

### Phase 9: Runners & conversation features (ported from Biscuit Bots)
Core only (`Sources/LaunchpadCore`); the app's wiring and UI come next (integration notes below).

- **Local models** (`Runner/LocalModel.swift`): new `BotEngine.local` (Ollama, LM Studio or any OpenAI-compatible
  server). `Bot.localBaseURL` (nil = `http://localhost:11434/v1`; `localhost:1234` style input is normalised).
  `EngineCommand.invocation` builds a `LocalModelRequest` (in `EngineInvocation.local`) from the bot's CLAUDE.md, a
  "you have no tools" note, the chat so far (`RunOptions.history`, newest 24k characters, other bots named in
  groups) and the prompt. `EngineRunner` POSTs `{base}/chat/completions` with `stream: true` through URLSession
  (FoundationNetworking on Linux), reads SSE deltas (or a whole JSON body if the server ignores `stream`), and Stop
  cancels the request. Plain-English errors: server not running ("Start Ollama…", with `ollama serve`), model not
  downloaded (`ollama pull <model>`), wrong address, chat too long. Local servers bypass proxies.
- **Backup brain** (`Runner/Recap.swift`): `Bot.backup: BotBrain?` (engine + model). `BackupPolicy.retryBrain` says
  retry only after a usage-limit failure, once, and only on something different; `Bot.running(on:)` swaps the
  engine for one turn; `BackupPolicy.prompt` adds a recap (a local backup gets the chat as history instead).
- **Recaps** (`ConversationRecap`): one builder for every "this model hasn't seen the chat" case: no session
  (Compact, Branch, lost session, backup) → recent 12 messages in front; a session that missed messages
  (`unseenAfter`) → just those. Notices, failed and half-written replies are left out.
- **To-do list** (`Runner/Progress.swift`): `RunEvent.todos([TodoItem])` from Claude's TaskCreate / TaskUpdate (the
  task number comes from the tool result) and TodoWrite, and Codex `todo_list` items (now also `item.updated`).
  `MessageBuilder.todos` holds the live list (not saved in `ChatMessage` yet).
- **Context meter**: `RunEvent.context(ContextUsage)`. Claude: each call's input (incl. cached) from `assistant`
  usage, window from the result's `modelUsage.*.contextWindow`. Codex: `CodexSessionLogs.context(threadId:)` reads
  Codex's own count (`last_token_usage`, `model_context_window`) from its session log, because `turn.completed`
  usage is the whole session's running total. Local: the server's `usage` when it sends one.
- **Codex usage from session logs** (`CodexSessionLogs.usageReport()`): newest `~/.codex/sessions/**/*.jsonl` with a
  `token_count` `rate_limits` (used_percent, window_minutes, resets_at) → `UsageReport(engine: .codex, windows:)`
  named five_hour / seven_day like Claude's. `UsageSnapshot.codexWindows` (optional, old usage.json still loads).
- **Codex home** (`Runner/CodexHome.swift`): one Launchpad CODEX_HOME (Application Support/Launchpad/codex-home,
  outside ~/Launchpad so our sandbox doesn't block Codex's writes) with everything linked to ~/.codex except
  config.toml, which is your config minus `[mcp_servers.*]`. So a Codex bot only gets its own connectors (Codex
  has no strict-MCP switch) but keeps your model/provider/profile settings. A sign-in Codex saved over our link is
  copied back to ~/.codex. Shared rather than per bot: everything per bot is passed with `-c` anyway.
- **Steering & batching** (`Runner/Steering.swift`): `TurnQueue` (per chat). Writing to a busy bot in a 1:1 chat
  steers (stop the run, next turn carries on with a "don't start over" note); otherwise messages queue and become
  one merged turn (teammates first, yours last). A run stopped before its session existed re-sends the first message.
  `settleInterrupted` keeps a cut-short reply as done (or drops it if empty).
- **Threads** (`Threads.swift`): `ThreadStore` keeps earlier conversations in `chats/threads/<chat>/` (`index.json`
  + `<thread>.jsonl`). New thread (archive messages + sessions, start empty), Compact (keep messages, clear
  sessions → recap next turn), Branch from a message (new chat with messages up to it, no sessions), reopen, delete,
  and per-bot `unseenAfter` marks. `ChatStore.loadAll` ignores the folder.
- **Side questions** (`Runner/SideQuestion.swift`, `RunOptions.forkSession`): Claude `--resume <id> --fork-session
  --session-id <new> --no-session-persistence`; Codex `codex exec fork --json --ephemeral … <id> -`. Read-only, no
  session kept; without a session (or for a local bot) a fresh run with a recap. Verified live: Claude Code 2.1.326
  forked a haiku session (new id, remembered the earlier context; `--session-id` with `--fork-session` works);
  codex-cli 0.169 `exec fork` accepted the flags and started a new thread (`thread.started`) from a copied session
  (no sign-in here, so no reply).
- Fixtures: `claudeTaskRun` is trimmed real output (Claude Code 2.1.326, haiku, TaskCreate/TaskUpdate). TodoWrite
  isn't offered by 2.1.326, so it's tested on the tracker directly. The Codex `token_count` and `todo_list` lines
  are written from codex-cli 0.169's event shapes (no signed-in Codex to capture from).
- Not ported: Biscuit's per-thread session keys (Launchpad already keeps sessions per chat), voice-call recaps,
  routine run threads, and a local API key setting in the UI (`RunOptions.localAPIKey` is ready for a Keychain value).

Tests: 315 (plus 2 opt-in live ones). New `LocalModelTests` (16, including a fake HTTP server: streaming, non-streaming,
missing model, nothing listening, Stop) and `ConversationFeatureTests` (25).

### App integration: safety, routines and work
The macOS app now uses the safety, routines and work cores. New files: `SafetyViews.swift`, `RoutineViews.swift`
(the routine list and editor, moved out of LibraryViews), `WorkViews.swift` (Tasks and Workflows) and
`AppModel+Work.swift`.

**Safety**
- **Per-reply guard** (`AppModel.prepareRun`): each Claude reply gets its own run id. The bot's rules file is written
  (`GuardRulesFile`, including locked skill folders and the Settings choice) and `RunOptions.guardHook` is set with an
  `--ask` base for that reply. Bots are told about live approvals (`LaunchpadProtocol.text(liveApprovals: true)`).
  If the helper is missing or the rules can't be written, a bot with custom rules or a locked skill doesn't run
  ("Couldn't start the safety check, so … didn't run."). Other bots fall back to the older `--approvals` guard as before.
- **Live approval cards**: while a reply streams, the app checks the inbox every 0.5 s. New cards appear in the reply
  with the category and the readable tool name shown big, then the details. You can Approve, Decline, or pick Always
  allow (only shown when the card offers it, and not for writes when the bot is locked down or the Settings switch is off).
  Always allow saves the bot, rewrites its rules file and answers any other waiting cards with the same
  category:tool. Cards whose key is already always allowed are answered by themselves. When the reply ends, the
  inbox is closed and cards still waiting show as expired. Cards are saved on the reply (`ChatMessage.liveApprovals`).
  The older `[[approve: …]]` card still works.
- **Sandbox**: when `sandbox-exec` exists, every bot runs inside `BotSandbox.profile()`. Codex is only wrapped when it
  runs without its own sandbox. A locked-down bot refuses to run when there's no sandbox.
- **Site gateway**: locked-down bots get a per-reply gateway token (their own sites, plus their engine's and
  connectors'), their proxy environment, and a line in their instructions. The token is revoked when the reply ends.
  If the gateway can't start, the bot doesn't run.
- **Codex**: `bot.rules.codexNote(lockedSkills:)` is added to its instructions.
- **Undo**: before each reply the bot's folder is snapshotted off the main thread. Afterwards the changed files are
  saved on the reply (`snapshot`, `changedFiles`). A "Changed N files · Undo" bar asks you to confirm, lists the
  files, restores them, marks the reply `undone` and posts a notice. Undo is refused while that bot is working.
  `Snapshots` is created in the background at launch because finding git can be slow. Without git, Undo is off.
- **Keychain**: `KeychainSecretStore.read` returns found / missing / failed, using the Keychain's own message when it fails.
- **UI**: in the bot editor, Permissions (Ask/Allow/Never per category), an Always allowed list (removals survive cards
  answered while the editor was open, via `BotRules.merged`), your own "change" commands (bad regexes are flagged and
  dropped on save), and Lock-down with its sites (engine and connector sites are shown read-only). Skills have a
  Lock toggle, which rewrites every bot's rules file. Settings has the "Always allow for sends, deletes, spending and
  changes" switch (`alwaysForWrites`, stored in UserDefaults), plus sandbox and undo status.
- `ChatMessage` gained the optional `liveApprovals`, `snapshot`, `changedFiles` and `undone` fields, and the new
  `LiveApproval` type. Older JSONL still decodes (test added).

**Routines & work**
- **Routine editor**: covers every trigger (daily, weekly, hourly, every…, once, a new file, a web address). It shows
  the next run, has "If missed while closed, run once when you're back" (catchUp, clock triggers) and "Each run in
  its own chat" (ownChat), a missed-runs banner with Run now / Skip, and a warning when the folder is missing.
  Web address routines show their address, a secret you can show, hide or copy, a curl example, New Secret
  (with confirmation), and Try again if the Keychain refuses. Saving goes through `preparedForSave(stored:)`.
  Deleting a routine forgets its secret.
- **Timer**: every 20 s, `RoutineSchedule.tick` runs (due, catch-up with a notice, and missed runs that get a notice
  plus the banner), then `workflowEngine.reloadWorkflows()` and `startDue()`, then the listener sync. Folder routines
  are checked every 3 s with `FolderTriggers.poll`, which replaces `NewFileWatch`. `fire` follows the notes: it uses
  `runMessage(payload:)`, own-chat or the routine's chat, `markRan` (deleting old run chats) and logs the run.
- **Web address listener**: `LoopbackHTTPListener` on 127.0.0.1:8791 runs only while an enabled web address routine
  exists. Secrets are cached from the Keychain. If the port can't be opened, the routine shows the problem and
  Launchpad tries again on the next tick.
- **Workflows**: `AppModel` is the `WorkflowStepExecutor`. Bot steps run in a "🔁 <workflow>" chat with that bot or
  group. They wait for the chat to be free, and stopping or a timeout stops the chat. A group's replies are joined as
  "Name: text". `finishedReply` lets a resumed run use a reply that already came in. Approval steps bounce the Dock
  icon and wait in Tasks. Output steps post a "📤" notice in the target's chat.
- **New sidebar section "Work"** with Tasks, Workflows and Routines:
  - **Tasks**: send a task to a bot or group. It goes to the everyday chat, or a new chat if that one is busy.
    Each task shows its status (Waiting, Working, Needs you, Done, Didn't finish) and its replies. Approval tasks
    have Approve / Decline, and you can dismiss tasks. The sidebar badge counts tasks that need you.
  - **Workflows**: a list plus an editor (name, on/off, a schedule using clock triggers only, and steps of every
    kind with their target, timeout, match and save-to-file settings; steps can be reordered). It also has
    Run / Stop, a resume banner after a quit, a Runs tab with each step's result, and a History tab with the whole
    run log.

**Decisions**
- The rules file is per bot, so it's always written with *every* group folder the bot is in as an extra root (not just
  this chat's). Otherwise a solo chat and a group chat running at once would keep rewriting each other's file.
- `FolderTriggers.prime` runs at launch, and on an editor save only when the folder is new or the routine was just
  switched on. Priming a folder that's already watched would swallow files that have arrived but not yet been reported.
- Core change: `WorkflowEngine.record(_:)` adds routine runs to the history. Using `store.appendLog` from the app
  would be overwritten by the engine's next save of its own copy (test added).
- Missed-run notices go to the routine's latest chat. If it has none, they only show as the banner.

**Not done / left out**
- `create_routine` for bots (`RoutineRequests`) is still for later (via MCP).
- No `.workflows` area in `FolderWatcher`. Workflow files are re-read on each 20 s tick instead.
- Approval steps don't send a system notification (that needs UserNotifications permission in a signed app). The Dock
  bounces and the Tasks badge shows.
- `trustedServers` is always empty (there's no UI for it yet).

Tests: 2 new (old chat lines decode and the safety fields round-trip; routine runs recorded through the engine
survive its saves). 276 in total, all passing on Linux. The app is built and bundled by the macOS CI.

### App integration: chat tools, chat features and runners
The macOS app now uses the Phase 8 and Phase 9 cores. New files: `AppModel+Chat.swift` (chat tool actions, cards,
message operations, attachments, export, ⌘K, drafter, team notes, threads, side questions, Codex usage) and
`ChatFeatureViews.swift` (reactions, GIFs, plan / question / poll cards, file chips with Quick Look, to-do list,
message menu, pinned bar, saved messages, quick switcher, context ring, thread menu, past threads, activity feed).

**How a reply runs now** (`AppModel.runBotTurn`, split into `prepareRun`, `streamRun` and `finalMessage`)
- `prepareRun`: agent bots get a `ChatToolsRun` for the reply (actions file prepared, `launchpad-chat` added to their
  connectors when it's bundled next to the app, `ChatToolsSetup.allowingChatTools` on Claude's `--allowedTools`), the
  chat tools instructions, `TeamNotes.teamLine` and `paths.shared` as an extra folder. The guard rules file now has
  `trustedServers: ["launchpad_chat"]` and `Shared/` as a root, so react / send_gif / share_plan and TEAM.md edits
  don't ask. Codex runs get `CodexHome().environment()`. Local bots get the chat as `history`, bot names, and an
  optional API key from the Keychain (`local-model-api-key`), and no guard, sandbox, chat tools or undo snapshot.
- `streamRun`: one poller every 0.5 s collects approval cards and reads the actions file (`ChatActionReader`), applied
  with `ChatActionApplier`: reactions / votes on earlier messages are saved, GIF searches go to GIPHY (first result),
  `create_routine` requests are saved for this chat's bot or group with a notice, and the reply's cards show live.
  A plan whose countdown runs out shows as started. The `.context` event fills the header's context ring.
- `finalMessage`: approval cards expire, the to-do list is saved on the reply (`ChatMessage.todos`), the text
  fallback (`ChatTokens`) is applied, extras are merged and the run's files are cleaned up.
- 1:1 chats: every agent turn goes through `ConversationRecap.prompt` (no session → recent chat in front; missed
  messages after a backup turn → just those), and a finished turn clears `unseenAfter`. The session-lost retry gets
  the recap the same way. Local bots never get a recap (they get the whole chat as history).
- Backup brain: after a usage-limit failure, `BackupPolicy.retryBrain` → notice, one turn on `bot.running(on:)` with no
  session and `BackupPolicy.prompt`; its session is never saved; the main session gets an `unseenAfter` mark.
- Replies in 1:1 chats are paced with `TextPacing.splitIntoTexts` (a typing indicator between parts). Group replies
  aren't split, so hand-off and summary text stays in one message.
- After a Codex turn, `CodexSessionLogs.context(threadId:)` (off the main thread) updates the ring, and usage is
  refreshed; a timer also refreshes Codex usage every 2 minutes. The sidebar shows `codexWindows` like Claude's.

**Steering and queueing** (`TurnQueue` per 1:1 chat)
- Send stays enabled while a bot works. In a 1:1 chat, writing to the busy bot steers it: its run is cancelled (Stop
  keeps the session), the cut-short reply is kept with `settleInterrupted` (or dropped if empty), and the next turn
  carries on with your words. Messages written while a teammate or reviewer is answering wait and are merged.
  In a group, a message written while the group works is saved and the group runs again when it's free.
  Routines, workflows and buttons still wait for a free chat. Stop clears the queue.
- `startSolo` loops: the bot's turn, then 1:1 hand-offs (`DirectHandOff`: notice, helper turn, answer back to the chat's
  bot, hop limit; skipped when you've written meanwhile), then the next queued turn.

**Chat features (UI)**
- Cards: plan (Start / Cancel, countdown from Settings → Chat → Plan cards; Start on a reply that has ended sends
  "Go ahead with the plan."), questions (tappable options, multi-select, your own words; group answers @mention the
  asker), polls (vote, counts, voters, bots' reasons; voting in a bot's poll tells it), GIFs (animated via NSImageView).
- Right-click a message: React, Pin, Save for Later, Copy Text, Edit (your messages; earlier versions kept), Forward to
  any chat (that chat's bot or group answers), Ask for Review (another bot, same chat, no hand-offs), Branch from Here,
  Delete ("This message was deleted"). Reactions show under messages; click one to add or remove yours.
- Pinned bar above the messages (click to jump), Saved messages sheet (chat list toolbar, ⇧⌘S), ⌘K quick switcher
  (chats, bots, groups, pages, actions and message text, arrow keys + Return).
- Composer + menu: Attach Files, Send a GIF (GIPHY key in Settings), Start a Poll, Ask on the Side (1:1), Saved
  Prompts (use / save what's typed / remove). Files can also be dropped anywhere on the chat; they're copied into the
  Inbox and listed in your message. Huddle replaces "Ask everyone" in groups (`Huddle.message` + started notice).
- Header: Thread menu (New Thread, Compact, Branch from Here, Past Threads… with reopen / delete and a read-only peek),
  context ring with a Compact button when it's nearly full, Export (Markdown via a save panel).
- Bot replies: to-do list above the steps, steps labelled with `StepLabel`, mentioned files as chips (Quick Look),
  side questions and answers marked "Side question". Activity popover in the chat list toolbar (`ActivityFeed`).
- Bot editor: engine picker with Local model (server address with Ollama / LM Studio presets; model required), Backup
  brain (engine, model, address), and agent-only sections (permission, skills, connectors, permissions, lock-down)
  hidden for local bots. New Bot sheet: "Describe your bot" → `BotDrafter` (an agent engine you have) fills name,
  role, emoji, colour and instructions. Settings: Local model (Ollama status, Start Ollama, API key), Chat (plan
  wait, GIPHY key), Team notes editor (TEAM.md, created from the template at launch). Sidebar: the local engine row
  only shows once a bot uses it ("Ollama found" / "server needed").

**Core changes**
- `ChatMessage.todos: [TodoItem]?` and `ChatMessage.isSide: Bool?` (optional; old JSONL still decodes, test added).
- `GroupPrompts` uses `ChatOps.contextText`, so group bots see GIFs, polls, files and forwards.

**Decisions**
- The chat-tools instructions are added even when the server isn't bundled (`swift run`), since the text fallback
  (`[react: 🎉]` …) still works there.
- Side questions run as live runs flagged `isSide`: they show in the chat and get approval cards, but don't make the
  chat busy, never save a session and have no chat tools.
- The plan-wait setting is app-wide (UserDefaults `planWait`), as in the core notes.

**Not done / left out**
- Answering a question card while the bot is still running sends your answers as a new message (which steers it).
- GIFs a bot asks for need the GIPHY key; without it they're skipped quietly.

Tests: 1 new (to-do list and side flag round-trip; old lines decode). 360 in total on Linux, all passing. The app is
built and bundled by the macOS CI.

## Phone link and iOS app (2026-11-17)

Ported Biscuit Bots' phone link and iPhone app. The bots keep running on the Mac; the phone is a remote for chats.

### What was built

**Core (`LaunchpadCore/PhoneLink.swift`, Linux-tested)**
- `PhoneLinkServer`: HTTP on port 8790 on every interface, using `LoopbackHTTPListener`, which now takes
  `interface: .all` (the web address routines still use the loopback default). Routes: `/hello` (no token),
  `/pair`, `/rev`, `/state`, `/messages`, `/send`, `/side`, `/answer`, `/read`, `/stop`. BB's `/avatar` dog
  endpoint is gone: bots and chats carry their emoji and colour instead.
- Request handling is pure: the server calls an injected `PhoneLinkBridge` (the app, or a fake in tests) for a
  `PhoneSnapshot` (bots, groups, chats, messages including streaming replies, who's working, read marks) and for each
  action. `PhoneMapper` turns the snapshot into the phone's JSON (`PhoneState`, `PhoneChat`, `PhoneMessage`).
- `/rev` is a stable FNV-1a fingerprint (not `Hasher`, which is seeded per run) of the state plus the tail of each
  chat: streaming text, steps, reactions, answered questions and approval cards all move it.
- **Pairing**: a 6-digit code (ASCII digits, spaces/dashes ignored, constant-time compare). A used code changes.
  After 5 wrong codes in 5 minutes pairing is refused (429) and the code is replaced, so one code never gets more
  than 5 guesses.
- **Tokens**: 32 random bytes per phone, stored in the SecretStore (`phone.<device id>.token`, the Keychain in the
  app). `~/Launchpad/.launchpad/phones.json` only holds names and dates. Every request compares the given token with
  every paired token in full (`WebhookAuth.constantTimeEquals`). Remove a phone and its token stops working at once.
  At most 20 phones.
- Requests with `Origin` or `Sec-Fetch-Site` (browsers) are refused, so a web page can't pair or guess.
- `/answer` takes a question card (`message` + `answers`), an `[[approve: …]]` card (`message` + `approve`) or a
  live guard card (`card` + `decision`: approve, deny, always). `/send` refuses a working chat with 409 instead of
  dropping the message; `replyTo` quotes the first line of that message.

**Mac app (new files only, plus two marked hooks)**
- `PhoneLinkController.swift`: starts and stops the server, publishes it with `NetService` as
  `_launchpad._tcp` (TXT: host = the Mac's `.local` name, port, v), the pairing code, paired phones, and the Mac's
  IPv4 addresses (Wi-Fi first, Tailscale 100.x last) for typing in by hand. Off until switched on.
- `AppModel+Phone.swift`: `AppPhoneBridge` (main actor, weak model). Sending goes through `AppModel.send`;
  approvals through `respond(to:)` and `answerApproval`; Stop through `stop`. Question cards are answered with
  `ChatOps.answer` (in a group the asking bot is @mentioned), marking the card answered. Side questions ask the
  bot (or a group's lead) from a read-only fork of its session (`SideQuestion.invocation`, `quiet`: no tools, in the
  sandbox when available); the question and the 💭 answer appear in the chat. Locked-down bots refuse side
  questions for now. Read marks live in UserDefaults; the chat open on the Mac counts as read while you look at it,
  and replies from before the switch was first turned on aren't unread.
- `PhoneSettingsView.swift`: Settings › Mobile with the switch, status, pairing code and New code, addresses, and
  paired phones (last seen, Remove with confirmation).

**iPhone app (`iOS/`)**
- `LaunchpadPhone` target, bundle id `app.launchpad.phone`, iOS 17, display name Launchpad. Ported from BB's app:
  pair (Bonjour list or typed address, then the code), chat list (All / Unread / Bots / Groups, search), chat
  (markdown, steps, typing, reply, Stop). New: question cards with choices, approval cards (Approve / Decline /
  Always when allowed), and sending while a bot works becomes a side question. The token is in the iPhone's Keychain.
- No MabryPro fonts or Biscuit assets: system fonts, emoji avatars on the bot's colour, an SF Symbol on the pair
  screen, no app icon yet, and a placeholder blue accent kept in `Theme.swift` for the restyle.
- `project.yml` (XcodeGen) and a checked-in `LaunchpadPhone.xcodeproj` with a shared scheme. CI job `ios`
  (macos-15) builds the checked-in project, then generates one from `project.yml` and builds that too.

### Decisions
- The phone link reuses the POSIX listener instead of `NWListener`, so the same server is tested on Linux with a real
  socket. Bonjour stays in the app (`NetService`).
- Pairing is open whenever the switch is on, as in BB; the rate limit and code rotation keep guessing impractical.
- Plain HTTP on the LAN, as in BB: tokens are long and per phone, but anyone who can sniff the Wi-Fi could read
  traffic. Fine for a home network or Tailscale; TLS would need a certificate the phone trusts.

### How to try it
1. Mac: Launchpad › Settings › Mobile › switch on "Chat from your iPhone". Allow incoming connections if macOS asks.
2. Open `iOS/LaunchpadPhone.xcodeproj` in Xcode (or `cd iOS && xcodegen generate`), pick your team under Signing &
   Capabilities, and run on your iPhone (or the simulator). Allow Local Network access.
3. Pick your Mac (or type an address from Settings), type the 6-digit code.
   Debug builds also accept `-autopair http://<mac>:8790 <code>` as launch arguments.

### Not done
- No push notifications (the phone polls `/rev` every second while open).
- Attachments, reactions, polls and plan cards are shown read-only (or not at all for plans) on the phone.
- Side questions don't run for locked-down bots (they need the site gateway set-up that `prepareRun` keeps private).

Tests: 15 new in `PhoneLinkTests` (pairing and token storage, lock-out and code rotation, auth and browser refusal,
revoke, state mapping with unread and typing, revision changes, messages with cards and questions, deleted
messages, send with quote and busy/oversize/unknown, answer routing, a real socket). 374 in total, all passing on Linux.

## Final round: Mac features and computer use (2026-11-17)

Ported the remaining Mac features from Biscuit Bots (`QuickAsk.swift`, `MenuBarContent.swift`, `OfficeView.swift`,
`PopOut.swift`, `TopBar.swift`'s history, `Core/Awake.swift`, `Core/ComputerUse.swift`), adapted to Launchpad: no
Biscuit names, no dog art or office props (cards with the bots' emoji avatars), the brand template icon in the menu bar.
Left out on purpose: voice (dictation, calls, read-aloud), the notch Island, the updater and recovery, FigmaInbox.

Before that, the macOS build on `main` was checked: the failure the previous worker stopped on (`live` / `messages`
setters in `AppModel+Chat.swift`) was already fixed on `port/app-integration` (its CI run built, tested and bundled),
and the chat/runner wiring matches the integration notes (chat tools, cards, message actions, attachments, export, ⌘K,
drafter, team notes, hand-offs, huddles, pacing, file chips, step labels, local models, Codex home, recaps, backup,
to-dos, context ring, Codex usage, threads, side questions, steering).

### What was built

**Core (`LaunchpadCore`, Linux-tested)**
- `Desktop/ComputerUse.swift`: where Cua Driver lives (`~/.local/bin`, `CuaDriver.app`, Homebrew, your PATH), the
  installer command, the private socket (`<tmp>/launchpad-cua/driver.sock`), the "computer" MCP connector
  (`/bin/sh -c 'wait for the socket; exec cua-driver mcp --socket …'`), `allowingComputer` (adds `mcp__computer` to
  Claude's `--allowedTools`, so a call the guard lets through isn't refused by Claude Code), `Blocker` (why a bot can't
  use the Mac on this reply: switched off, not Claude, locked down, Never, no guard, no driver, no Accessibility, no
  Screen Recording, driver failed) and the bot's instructions (background only, session label, claim apps first).
- `AppClaims`: reads `.launchpad/scratch/app-claims.json` (written by the chat tools' use_app / done_with_app, 15 min
  expiry) and releases a bot's claims under the same `flock` when its reply ends.
- `Bot.useComputer` ("Use this Mac", off by default; older bot.json files load).
- `Office.swift`: `Attention` (a pending approval card or `[[approve]]`, an unanswered question card, a plan waiting
  for Start; only a chat's latest message counts), `DeskState` (needs you, working, up next, free) and `WorkSummary`
  (what a working bot is doing: in-progress to-do, last step, thinking, writing), `NavigationHistory` (back/forward
  stacks with a limit) and `ReplyNotice` (notification text for finished, stuck and needs-you replies and for live
  approval cards).
- `ChatToolsSetup.allowing(_:in:)` generalises the `--allowedTools` helper.

**Mac app**
- **Office** (new sidebar page under Talk, ⇧⌘O): the list column is the live activity feed (started, each tool step
  in plain words, asked, finished, got stuck; click to open the chat); the detail is a desk card per bot with its status
  badge, what it's doing and for how long, the app it has claimed, and Watch (its live chat in its own window), Chat
  and Stop, plus the team notes (TEAM.md) with an editor sheet. Needs-you comes from live replies and the 20 most recent
  chats (loaded when the Office opens). The sidebar badge counts bots working.
- **Menu bar extra** (`MenuBarExtra`, window style): the template icon from `Resources/Brand/MenuBarIcon.png`/`@2x`
  (loaded through `AppResources`, `isTemplate = true`) with a count while bots work; the panel shows status, an "Ask
  your team" bar (Quick Ask), Working now (what each bot is doing, Stop per bot, Stop All), Needs you, recent chats,
  and New Bot / Office / Open / Settings / Quit. Switch it off in Settings › This Mac. With it on, closing the main
  window keeps Launchpad running; the main window is now a single `Window` that reopens from the menu bar or the Dock.
- **Quick Ask**: ⌃⌥B anywhere (Carbon `RegisterEventHotKey`) opens a floating, non-activating panel: pick any bot or
  group, type, Return. It goes to that target's everyday chat (like the composer, so a busy 1:1 bot is steered) and the
  reply streams into the panel; follow-ups stay in the same chat; Open Chat jumps there. Also in File › Quick Ask… and
  the menu bar. Switch the hot key off in Settings.
- **Pop-out chats**: Open in New Window from the chat header or the chat list's context menu (`WindowGroup` with a chat
  id); the Office's Watch opens the same window.
- **Back / forward**: ⌘[ and ⌘] (Go menu) and toolbar buttons, across pages and their selection (chat, bot, group,
  skill, connector, routine, task, workflow). Moves made by Back/Forward aren't recorded as new visits; deleted chats
  are dropped from the history.
- **Keep awake**: an `IOPMAssertionCreateWithName(PreventUserIdleSystemSleep)` while any chat is busy or any reply
  (side questions too) is streaming; released when everything stops or the app quits. Settings switch, on by default.
- **Notifications** (`UNUserNotificationCenter`, only inside the .app): while Launchpad is in the background, a
  notification when a chat's work ends (replied, got stuck, or needs you), when a live approval card appears, and when a
  bot asks a question card or shares a plan. Reply sends your text to that chat (`submit`, so it steers a busy bot);
  clicking opens the chat. Settings switch, on by default.
- **Computer use**: Settings › Computer use shows Cua Driver (installed path, or Install in Terminal… which opens the
  official installer in Terminal, never run silently), Accessibility and Screen Recording (`AXIsProcessTrusted`,
  `CGPreflightScreenCaptureAccess`, with buttons that ask macOS and open the right Privacy pane), whether the driver
  runs, which bots may use the Mac, and who's using which app. The bot editor has "Use this Mac" with its status and a
  Set Up… button. For each main reply of a bot with the switch on, `prepareRun` checks the blockers; if clear it starts
  Launchpad's private driver (`cua-driver serve --socket …`, restarted if it died, not retried for 10 min after a
  failure, leftovers from a crash killed at launch), adds the "computer" connector and the instructions; otherwise the
  bot is told in one line why it can't. Every computer call goes through the guard's "Use your Mac" category (Ask by
  default, so it shows an approval card; Always allow works per tool; Never blocks). When the reply ends the bot's app
  claims are released (unless it's still working in another chat). Side questions never get the computer tools.
- `AppResources`: the resource bundle in `Contents/Resources` (make-app.sh now copies `Launchpad_Launchpad.bundle`
  there) or SwiftPM's when run with `swift run`. Marketplace logos use it too.

### Decisions
- Computer use is Claude Code only: Codex has no tool hook, so its clicks couldn't be asked about one by one. It also
  needs the live guard (the bundled `launchpad-guard`), and locked-down bots never get it (they can't open other apps).
- The driver socket lives in the temporary folder, as asked (`<tmp>/launchpad-cua/driver.sock`); bots that aren't
  locked down can reach it from the sandbox (`allow default`).
- Watching a bot opens its real chat in a window rather than BB's read-only step sheet, so you can answer its cards
  and stop it from there.
- Notifications are per chat when its work ends (not per bot turn), so a group posts one notification, not one per
  member.
- The main window became a single `Window` scene (no ⌘N duplicates) so the menu bar and Quick Ask can always find or
  reopen it.

### Not done / left out
- Voice, the notch Island, the updater, recovery and FigmaInbox (as agreed).
- No quit guard ("bots are still working, quit anyway?").
- Needs-you in the Office only sees chats whose messages are loaded (the 20 most recent plus any you've opened).
- macOS ties Accessibility and Screen Recording to the app's signature; an ad-hoc signed build from make-app.sh may
  need the permissions granted again after a rebuild.
- Computer use was built against BB's working integration and Cua Driver's documented commands, but couldn't be run
  here (no Mac): try it by hand (checklist below in the hand-off).

Tests: 11 new in `MacFeatureTests` (useComputer round trip, driver lookup, connector and socket, every computer call
asks and Never blocks, allowed tools, blockers, claims read/release/expiry, attention, desk state and work line,
back/forward history, notification text). 386 on Linux (387 on macOS), all passing. The app is built, tested and
bundled by the macOS CI (run 18 onwards).

## Restyle: blue and black

The look the user approved (mockup `style/mock.html`, Biscuit Bots' layout and feel) in blue and black. Visual only:
every page, action and keyboard path works as before.

### What changed
- **Tokens** (`Theme.swift`): background `#06070A` / `#EDF0F5` with a faint blue glow top-right, frosted panels
  (`#111318` / white, slightly see-through over a material), cards `#171A21` / white, lines, text, secondary text,
  accent `#3B82FF` / `#1F6BFF` (gradient to `#1E5EEA` / `#0B4FD6`), soft accent `#16233F` / `#E6EEFF`, fields, code
  boxes, success, red and amber. Spacing 4/8/12/16/24/32; radii 18 control, 20 bubble, 24 card.
- **Reusable pieces**: `PillButtonStyle` (primary, soft, plain, destructive), `SoftButtonStyle`, `CircleButtonStyle`,
  `CircleIconButton`, `CircleMenu`, `PillTabs`, `SearchField`, `PillFieldStyle`, `CountBadge`, `RoleTag`,
  `SectionHeader`, `IconTile`, `ColumnHeader` / `.columnHeader`, `EmptyState`, `.panel()`, `.card()`,
  `.themedForm()`, `.sheetBackground()`, `GlowBackground`, `BrandMark` (the app icon, small and rounded) and
  `PanelList` with `.selectableRow(id)` (click to select, ↑ ↓ move, context menus kept).
- **Window**: `NavigationSplitView` replaced by three floating rounded panels on the glow (sidebar 228 pt, list
  column 260–460 pt, drag the gap to resize, double-click it to reset; the conversation fills the rest). The title is
  hidden and the toolbar is transparent with the Launchpad mark and name top-left, a sidebar toggle (⌃⌘S) and
  back / forward. Marketplace and Settings use the full width (no list column).
- **Sidebar**: Chats and Office, then Work, Team and Tools with small-caps headers; the selected row is a soft blue
  pill with blue text; counts are blue pills; the plan usage card (with thin usage bars and engine dots) and Settings
  sit at the bottom.
- **Chat list**: round search field and round compose button (the New Chat menu), pill filter tabs, round avatars on
  soft tints, role tags as grey pills, the selected chat as a card.
- **Conversation**: header with avatar, name, a green "working" status line, engine / permission chips and a
  context chip; round buttons (thread menu, new chat or group summary, a "more" menu with folder, edit, export and
  open in window) and a blue "Teach a Skill" pill (a round button when narrow). Your bubbles are a blue gradient with
  white text and a small tail corner; bot replies are cards with a thin border; the step summary is a soft pill;
  approval, live approval, plan, question and poll cards are 22 pt cards with pill buttons (primary solid blue,
  secondary soft blue); the composer is a round +, a pill field and a round blue send (red stop while working).
- **Everywhere else**: Office desks and team notes as 24 pt cards, the live feed column, Marketplace with pill tabs
  and cards, Bots / Groups / Skills / Connectors / Routines / Workflows / Tasks lists on `PanelList`, grouped forms
  on the panels (no grey page behind, switches for toggles, soft pill buttons), sheets on the solid panel colour with
  the glow, the menu bar panel and the Quick Ask bar restyled, pop-out chat windows as one panel on the glow, empty
  states with a soft icon tile. `.tint(Theme.accent)` stays on every scene.

### Decisions
- Contrast: accent-coloured text uses `accentText` (`#6AA5FF` dark / `#0B4FD6` light) so it reads at 4.5:1 or more on
  panels and soft-blue fills; small white-on-blue badges use `accentStrong`. Success, red and amber text use darker
  shades in light mode (`#0B7F4B`, `#C62F36`, `#A14A06`); the exact palette colours are kept for dots, bars and fills.
- Grouped `Form`s keep the system section cards (now on the panel colour) rather than a hand-made form, so labels,
  pickers and fields keep their native alignment and accessibility.
- Lists moved from `List(selection:)` to `PanelList`, because the system selection highlight can't be restyled.
- System fonts only: SF Pro for interface text, SF Pro Rounded for big titles.

Tests: no core changes; `swift build` and `swift test` still pass on Linux, and the macOS CI builds the app.

## Keep app data out of git (2026-11-17)

`.gitignore` now lists Launchpad's data folders at the repo root (`.launchpad/`, `Shared/`, `bots/`, `chats/`,
`groups/`, `skills/`, `work/`) and `connectors.json`. On a case-insensitive disk `~/Launchpad` (the app's home) and
`~/launchpad` (this checkout) are the same folder, so a `git add -A` could have committed chat history. The patterns
are anchored to the root so same-named folders deeper in the tree are unaffected; none of the names were tracked.
Moving the default data home out of the checkout is still open. No code changes.

## @-mention picker in group chats (2026-11-17)

Typing `@` in a group chat's composer did nothing: bots hand work to each other by @mention, but there was never a
picker for the person typing. Now there is one.

- **Core** (`Chat/MentionPicker.swift`): `query(in:)` finds the handle being typed at the end of the draft (the `@`
  must start a word, the same rule as `GroupPlan.mentions`), `candidates(for:among:)` filters the group's bots by id
  or name (prefix matches first, then contains, in group order) and `insert(_:into:)` replaces the typed handle with
  `@id `.
- **App** (`MentionList` and `Composer` in `ConversationView.swift`): a small list above the composer with avatar,
  name, role and `@id`. ↑ ↓ move (wrapping), Return, Tab or a click inserts the tag, Esc closes the list and keeps the
  text. With the list closed Return sends as before. One-to-one chats have no picker.

### Decisions
- The picker looks at the end of the draft, not the caret: `TextField` has no selection binding on macOS 14. Typing
  `@` in the middle of existing text doesn't open it.
- Esc remembers the draft it closed on, so the list stays shut until you type again.
- `onSubmit` also picks when the list is open, in case the field editor swallows Return before `onKeyPress` sees it.

Tests: 9 new in `MentionPickerTests` (what counts as a query, filtering and order, insertion, and that the inserted
tag is understood by `GroupPlan.mentions`).

## Version from git tags (2026-11-17)

Release plan step 1. Every build used to say `0.1.0 (1)`, so nobody could tell which build was installed.

- **`scripts/make-app.sh`**: the version is the newest `v*` tag (`v0.2.0` gives `0.2.0`; `0.1.0` until the first
  tag), the build number is the commit count, and `git describe` goes into a new Info.plist key,
  `LaunchpadGitDescribe`. A tag that isn't a plain version (`v1.0-rc1`) stops the build.
- **Core** (`AppVersion.swift`): reads those three values and makes the label: `0.2.0 (57)` on a tag,
  `0.2.0 (60, v0.2.0-3-gabc1234)` between tags, `Development build` under `swift run`.
- **App**: Settings shows a selectable **Version** row at the bottom.
- `.gitignore` also covers `routines.json` and `workflows/`, the two data names the first pass missed.

### Decisions
- `CFBundleShortVersionString` stays a plain `1.2.3`; the commit detail lives in its own key rather than the
  version string, which macOS and notarisation expect to be numeric.
- CI checks out one commit with no tags, so a CI-built app reads `0.1.0 (1)`. The release workflow (step 3) will
  fetch full history.

Tests: 5 new in `AppVersionTests`.

## Developer ID signing (2026-11-17)

Release plan step 2. The app was always ad-hoc signed, so every build had a new identity (macOS can re-ask for
Keychain and privacy permissions after each update), and `codesign ... || true` hid signing failures.

- **`scripts/make-app.sh`**: with `SIGN_IDENTITY` set, the two helpers (`launchpad-guard`, `launchpad-chat`) and then
  the app are signed with that certificate, the hardened runtime and a timestamp, which is what notarisation needs.
  Without it the app is ad-hoc signed as before. Either way a signing failure now stops the build, and the result is
  checked with `codesign --verify --strict`.
- **`scripts/Launchpad.entitlements`**: one entitlement, Apple Events, with a matching usage description in
  Info.plist. Bots run as Launchpad's child processes, so macOS asks on Launchpad's behalf when one scripts another
  app.
- README: how to sign.

### Decisions
- Entitlements start minimal. Launchpad loads no third-party code itself, and the engines (`claude`, `codex`) are
  separate programs with their own signatures, so no JIT or library-validation exceptions until a signed build shows
  one is needed.
- The helpers get their own identifiers (`app.launchpad.personal.guard`, `.chat`) rather than the file name.

Tests: no Swift changes. Built three ways: ad-hoc (as before); `SIGN_IDENTITY=-` (hardened runtime with an ad-hoc
identity: the app started on an empty home folder and the guard helper ran); and a missing identity (build stops,
exit 1). Not yet tried with a real Developer ID certificate.

## One-command release from the Mac (2026-11-17)

Release plan step 3, changed: releases are built on Oscar's Mac rather than on GitHub's runners, which were
queueing for 15 minutes and sometimes never starting.

- **`scripts/release.sh 0.2.0`**: checks first (on `main`, nothing uncommitted, level with GitHub, tag unused, `gh`
  signed in, a Developer ID Application certificate, a working `notarytool` keychain profile), then tags, builds
  with `SIGN_IDENTITY`, zips, notarises, staples, checks with Gatekeeper, pushes the tag and publishes the zip as a
  GitHub release. `--check` runs the checks only.
- Each missing piece stops the script with what to do about it, before anything is changed.

### Decisions
- The tag is created locally first (the build takes its version from it) and pushed only after Apple accepts the
  app; a failure before that removes the local tag, so a failed release can simply be run again.
- The certificate is found by its hash, not its name. `SIGN_IDENTITY` and `NOTARY_PROFILE` override the defaults.
- The script doesn't run `swift test`: one test fails on a Mac set to a 12-hour clock, which would block every
  release until that test is fixed.

Tests: every check's failure message was triggered in a throwaway clone. The release itself (signing with a real
Developer ID, notarisation, stapling, publishing) has not been run: there is no certificate on this Mac yet.

## Who's working, from the chat header (2026-11-17)

The green "working" line in a chat's header is now a button. Clicking it opens a small popover listing the bots
replying in that chat right now: avatar, name, what each is doing (the same line the Office shows) and how long it's
been going. It says "Handing over to the next bot…" between two turns in a group and "Nobody's working" when idle.

- **Core**: `WorkSummary.elapsed(since:now:)` gives "Just started", "4 min", "1 h 5 min". The Office's desks use it
  too, so a long run now reads "1 h 5 min" there instead of "65 min".
- **App**: `WorkingButton` and `WhoIsWorking` in `WorkingViews.swift`; the header swaps `WorkingStatus()` for the
  button in both group and one-to-one chats. The times refresh every 10 seconds while the popover is open.

Tests: 1 new (`testElapsedSaysHowLongABotHasBeenGoing`). The popover itself was not tried in the running app.

## Full freedom mode for groups (2026-11-17)

Each group now has an Approvals setting: **Ask me** (the default, today's behaviour) or **Full freedom**, where
anything a bot's rules would ask about (send or post, delete, spend, change code or shared systems, use your Mac)
goes through without an approval card.

Where approvals were decided before: `GuardEngine.decide` sorts a tool call into categories and returns pass, deny
or ask; `GuardHook.run` (the `launchpad-guard hook` Claude Code runs before every tool) turns ask into an approval
card and waits. Codex has no hook, so its Ask rules are instructions (`BotRules.codexNote`).

- **Core**: `ApprovalMode` and the `ApprovalModes` store (`Safety/ApprovalMode.swift`), which keeps the ids of the
  Full freedom groups in `full-freedom.json` in Launchpad's data folder (missing or unreadable means Ask me).
  `GuardConfig.fullFreedom` makes `GuardHook.run` answer an ask
  with allow, the same as you approving the card. `LaunchpadProtocol.text` and `BotRules.codexNote` tell the bot it
  needn't ask. `ApprovalMode.command(in:)` reads "accept mode" / "ask mode" typed as a whole message.
- **App**: a segmented Approvals picker in the group editor (it applies straight away, without Save), an amber "Full freedom" badge beside the group's name in
  the chat header (click it to go back to Ask me), "Switch to …" in the chat's More menu, and the typed commands.
  Every switch leaves a notice in the chat.

### Decisions
- Full freedom only loosens Ask. A category set to Never stays off, locked skills and Launchpad's own files stay
  protected, and a locked-down bot keeps asking: those were choices about one bot, and the group switch doesn't undo
  them. The rule about secrets is unchanged.
- It is per group and applies only in that group's chat; one-to-one chats always ask (`ApprovalModes.mode(for:)`).
- The mode is not in group.json. That file is in the group's folder, where its bots may edit files without asking,
  so a bot in Ask me could have switched Full freedom on for itself (Tester found this in review). It lives with
  Launchpad's own files instead, which the guard and the sandbox both refuse to let a bot write. Deleting a group
  clears its entry, so a later group with the same id starts in Ask me.
- A bot can be answering in an Ask me chat and a Full freedom group at once, so the Full freedom rules go in their
  own file (`rules/<bot>.free.json`) instead of rewriting the one the other run is reading.
- If the guard can't start, a Claude bot falls back to asking in chat even in Full freedom (fail closed).
- Plan cards (`share_plan`) and questions (`ask_user`) are not approvals and still appear.

Tests: 15 new in `ApprovalModeTests` (default, saving outside the groups folder, an unreadable file, group.json not
able to turn it on, one-to-one chats never free, a bot's Edit, Write and shell edits of the mode file refused, the
typed commands, the hook letting Ask through, Never and protected files still denied, locked-down bots still asking,
what bots are told).

## Who's working and who's idle, from the members line (2026-11-17)

In a group chat's header, the member avatars and the "8 members · lead: …" line are now a button. Clicking it opens
a popover listing every member, the working ones first and the rest in the group's order: avatar, name and role, then
a green dot with what the bot is doing and how long it's been going (amber when it's waiting on you), or a grey dot
and "Idle". The title row counts them ("3 working · 5 idle").

- **Core**: `WorkSummary.workingFirst(_:working:)` orders the members.
- **App**: `MembersButton`, `GroupMembersStatus` and a shared `BotStatusRow` in `WorkingViews.swift`. The green
  "working" line and its popover are unchanged and use the same row. The times refresh every 10 seconds.

### Decisions
- A member replying in another chat counts as working, with "· in <chat>" after what it's doing: the question is
  whether the bot is free, not only whether it's busy here.
- While the group works, the header shows the avatars (the members button) and then the "working" button; the
  members text only shows when the group is quiet, as before.

Tests: 1 new (`testWorkingMembersComeFirstInGroupOrder`). The popover was not tried in the running app.

## Update and install safe to run from inside the app (2026-11-17)

Groundwork for an Update button, so updating doesn't need Terminal. The scripts only; the check and the button
come next.

- **Build stamps** (`scripts/make-app.sh`): Info.plist now carries `LaunchpadGitCommit` (the full commit) and
  `LaunchpadSourcePath` (the checkout it was built in). Core reads them as `BuildStamp`, which also gives the path to
  `scripts/update.sh`.
- **Install without a gap** (`make-app.sh --install`): the new app is copied in next to the old one first; a running
  copy is asked to quit and waited for (15 s, then ended, then 10 s more); only then are the two swapped by rename.
  A failed copy, or an app that won't quit, leaves the installed app untouched. It used to delete the old app, wait
  one second and copy.
- **`scripts/update.sh`**: stops with a plain message when the checkout isn't on `main`, has uncommitted changes,
  can't reach GitHub or has diverged; a checkout that is only ahead still builds. One update at a time (a lock).
  Everything is logged to `~/Library/Logs/Launchpad/update.log` (`LAUNCHPAD_UPDATE_LOG` to move it): lines starting
  `==> ` are progress and the last is `==> Done: …` or `==> Failed: …`. Core's `UpdateLog.state(of:)` reads that.
- For testing: `SWIFT_BUILD_FLAGS`, `LAUNCHPAD_INSTALL_DIR` and `LAUNCHPAD_NO_OPEN` in `make-app.sh`.

### Decisions
- The running app is found by the path of its executable, not its bundle id, so installing into a test folder
  can't quit the real app. `pgrep` needs `-a`: it leaves out its own ancestors, and when the app starts the
  update, the app is one.
- Without a terminal, `update.sh` writes only to the log. Printing to an app that has just quit would kill the
  update between quitting and swapping.
- `update.sh` is one function, so bash has read all of it before the pull can replace the file under it.
- Signing is left as it is: the "Launchpad Local Signing" certificate (`scripts/setup-signing.sh`) already gives
  local builds a stable signature, so the Apple Development certificate isn't used as a third way to sign.

Tests: 3 new in `AppVersionTests` (build stamp, update log states). The scripts were run against a throwaway clone
and install folder: fresh install, install over a running copy (it quit and was replaced), a copy that fails, a
dirty checkout, the wrong branch, diverged, offline, a second update at once, a build that fails (installed app
untouched) and a full update with no terminal attached. Not run: a real update of /Applications/Launchpad.app, and
an update started by the app itself.

## Update check (2026-11-17)

The first piece of the in-app Update button: `UpdateCheck` in `Sources/LaunchpadCore/UpdateCheck.swift` says whether
GitHub's `main` has moved past the build that's running.

- `UpdateCheck().check(stamp:)` takes the `BuildStamp` from Info.plist, fetches `origin main` in the checkout the
  build came from and returns `.upToDate`, `.available(count:subjects:)` (how many commits behind and their subject
  lines, newest first, at most 30) or `.cantCheck(reason)`.
- `check(stamp:fetch: false)` compares with what the checkout last saw, without going online.
- `UpdateStatus.summary` is the one line for the banner and Settings.

### Decisions
- It never throws. Offline, an unstamped build, a moved checkout, a diverged build and git not starting are all
  `.cantCheck` with a plain reason, so the app can show it quietly or not at all.
- A build made from commits GitHub doesn't have yet (but which include GitHub's `main`) counts as up to date.
- The check only fetches: it never touches the checkout's branch or files. `scripts/update.sh` does the pulling.
- git runs with `GIT_TERMINAL_PROMPT=0` and is stopped after 30 seconds, so a dead connection or a password prompt
  can't hang the app. It blocks while it runs, so the app should call it off the main thread.
- git is injected (`UpdateCheck(git:)`), so the logic is tested without a network.

Tests: 14 new in `UpdateCheckTests`: 13 with a scripted git (each outcome above) and one against real temporary
repositories (up to date, two commits behind, the checkout left untouched, remote gone).

## Update button in the app (2026-11-17)

Launchpad now updates itself from inside the app, on top of the build stamps, `scripts/update.sh` and `UpdateCheck`.

- **Checking**: `Updater` (in `UpdaterViews.swift`) runs `UpdateCheck` off the main thread at launch and every three
  hours. A quiet check that can't reach GitHub shows nothing and keeps the last answer.
- **Banner**: when `main` is ahead, a bar across the top of the main window says "3 updates available" with the
  newest change, What's New (the commit subjects), Update and Later. Later hides it until more changes arrive.
- **Settings**: under Version, an Updates row (status and when it last checked), the list of what's new,
  Check for Updates and Update Now. A check you asked for shows the reason when it can't check.
- **Updating**: Update starts `scripts/update.sh` with its output on `/dev/null` so it outlives the app, then follows
  `update.log`: the banner shows each step. When the installer reaches "Waiting for Launchpad to quit" the installed
  app quits by itself; the script swaps the app and reopens it.
- **Bots working**: "Update now and stop them, or wait?" comes first. Update Now stops every bot, then updates.
- **Failures**: the app keeps running, and the banner gives the reason from the log with Show Details (the last 12
  lines of build output, `UpdateLog.detail`) and Try Again.

### Decisions
- The app quits itself at the quit step rather than waiting for the script's AppleScript request, which macOS may
  hold behind an Automation prompt. It only does so when it is the copy in Applications.
- The old log is removed before starting, so an earlier update's "Done" can't be read as this one's.
- Bots are stopped when you confirm, not at the quit step: the answer you gave is acted on straight away.

Tests: 2 new in `AppVersionTests` (the failure detail, and that the install script still prints the quit step the
app waits for). Nothing here was tried in the running app: the banner, the Settings rows, a real update started from
the button, the confirmation, and a failed build's error.

## Two tests that failed on every local run (2026-11-17)

Tests only; the app behaves as before.

- **`MissedRunTests.testCatchUpRunsOnceAndSaysSo`** expected "09:00" and got "9:00 am" on a Mac set to a 12-hour
  clock. The test was wrong, not the app: the missed-run notice follows the Mac's clock setting. `missedNotice` now
  takes a `locale` (default `.current`, so nothing changes in the app) and the test passes `en_GB`.
- **`SandboxTests.testKernelEnforcesTheProfile`** can't start `sandbox-exec` when a bot runs the tests, because
  macOS won't nest sandboxes. It now tries a trivial profile first and skips, saying why, only when that is refused
  with "sandbox_apply: Operation not permitted". From Terminal and in CI it runs for real as before.

Tests: 441 run from inside a bot's sandbox, 0 failures, 3 skipped (the kernel test, plus the two that were already
skipped).

## Capture a skill, and "/name" to use one: the core (2026-11-17)

What existed: skills are `skills/<id>/SKILL.md` in the library, given to a bot through its own or its groups' skill
lists and linked into its folder (`SkillLinker`); locked skills (`SkillLocks`) can't be changed by bots. "Teach a
Skill" in a chat header already drafts a skill from the last 30 messages and saves it to the library, but gives it
to nobody, and there was no way to use a skill by typing its name.

New in `Sources/LaunchpadCore/SkillCapture.swift` (no UI yet):

- **Saving**: `SkillDraft` (name, "use when" line, steps) and `SkillStore.capture(_:)`, which never overwrites: a
  name already in the library, or one of Launchpad's own skills, throws. `SkillStore.update(id:with:locked:)` edits
  one of your own skills in place and refuses built-in and locked ones. `SkillCapture.skillId(_:)` validates names.
- **Who gets it**: `SkillCapture.defaultAudience(for:)` is the chat's group (or the one bot of a one-to-one chat) and
  `SkillCapture.assign(_:to:bots:groups:)` adds the skill to the group's or the chosen bots' lists.
- **"/name …"**: `SkillCommand.query(in:)`, `candidates(for:among:)` and `insert(_:into:)` for the picker,
  `parse(_:skills:)` for a sent message and `prompt(for:)` for what the bot is sent.
- **Drafting**: `SkillTeacher.stretch(endingAt:in:)` picks the messages from your request to the chosen reply, and
  `SkillTeacher.capturePrompt(_:name:botName:)` turns them into the write-up prompt.

### Decisions
- A captured skill goes on the group, not on each member, so bots that join later get it too.
- "/name" only counts when the name is a skill in the library and is followed by a space or the end of the message,
  so paths like `/usr/bin/x` and unknown names stay ordinary messages.
- The prompt for "/name" carries the skill's text, so it works for a bot that doesn't have the skill linked.
- "accept" and "ask" can't be skill names: "/accept" and "/ask" switch the approvals mode.
- Saving only happens from the app. None of this is exposed to bots as a tool. (A bot can still edit an unlocked
  skill's file in its own folder, as before; lock a skill to stop that.)

Tests: 21 new in `SkillCaptureTests`.

## Save as Skill and /name in the composer (2026-11-17)

The app side of skill capture, on top of `SkillCapture.swift`.

- **Save as Skill**: the old "Teach a Skill" flow, renamed everywhere and extended. It's the header pill, an item in
  the chat's More menu and the chat list's menu (the whole chat), and "Save as Skill…" on a message's context menu
  (your request down to that message, `SkillTeacher.stretch`). The sheet (`TeachSkillSheet`, now in
  `SkillViews.swift`) has a name field with "Use it with /name" beside it, the bot's draft as editable text, and a
  "Give it to everyone in #group" (or the chat's bot) tick box, on by default.
- **Saving** goes through `SkillStore.capture` and `SkillCapture.assign`. A taken, built-in or unusable name is
  shown in the sheet and nothing is overwritten (it used to save as `name-2`). After saving you stay in the chat,
  with a notice saying how to use it.
- **`/` picker**: typing `/` at the start of the composer lists skills (`/id` and the "use when" line) in
  `SkillCommandList`, filtered as you type, with the same keys as the `@` picker (↑ ↓, Return or Tab, Esc).
- **Sending `/name request`**: in a one-to-one chat the bot gets `SkillCommand.prompt` (the request plus the
  skill's steps); your bubble still shows what you typed.
- **Skills list**: skills you made carry a "Yours" pill and an Edit item in the context menu.

### Decisions
- Group bots read the chat's history, not a prompt, so setting the prompt did nothing there. `SkillCommand.expand`
  swaps your "/name request" messages for the skill prompt in the history a group run is given. Only messages with
  the user role are expanded, so a bot writing "/name" can't pull a skill in; a routine's message can.
- The draft starts as soon as the sheet opens, as before; a name typed while it's being written wins over the
  bot's suggestion.

Tests: 1 new (`testGroupHistoryGetsTheSkillOnlyForYourMessages`). Nothing on screen was tried in the running app.

## Update button in the top right corner (2026-11-18)

The update banner is gone. In its place, an Update button appears by itself in the main window's toolbar (top
right) whenever GitHub's `main` is ahead of the build that's running, and is hidden when the app is up to date or
the check can't run.

- **Button** (`UpdateToolbarButton`): a blue "Update" pill with the number of waiting updates. While an update runs
  it reads "Updating…" with a spinner; if one fails it reads "Update Failed" until dismissed.
- **Popover** (`UpdatePopover`): what's new (the commit subjects) and Update Now; then the update's steps; or why it
  failed, with Show Details (the end of the build output), Try Again and Dismiss.
- **Bots working**: the popover asks "Update now and stop them, or wait?" inline, so no dialog opens over it.
  Settings › Updates is unchanged and keeps its dialog.
- **Checking sooner**: as well as at launch and every three hours, the app checks when you come back to it, at most
  every 10 minutes (`UpdateCheck.isDue`), since each check is a `git fetch`.

### Decisions
- One place to look: the banner and its Later button were removed rather than kept alongside the button. The
  button can't be dismissed while the app is behind.

Tests: 1 new (`testComingBackToTheAppChecksAtMostEveryFewMinutes`). Nothing was tried in the running app.

## Create ticket: the core (2026-11-18)

Select text in any Mac app, and a bot drafts and files a Jira ticket from it. This is the part with no UI (the
service, hotkey and capture panel come next). All in `Sources/LaunchpadCore/Tickets/`.

- **Settings** (`TicketSettings`, saved by `TicketSettingsStore` in `.launchpad/ticket-settings.json`): Jira project
  key (default BIS), the skill to use (default `biscuit-jira-tickets`), approval **Ask me first** (default) or **File
  without asking**, the assignee list (name + how Jira knows them), an optional Jira site host and the selection cap
  (default 20,000 characters). Read leniently; an unknown approval means ask.
- **The request and prompt** (`TicketRequest`, `TicketPrompt.prepare` / `build`): the selection, source app and
  window (best effort), a note and an optional assignee. `prepare` returns exactly what will be sent, with warnings
  (nothing selected, cut to fit, looks like it holds a secret) for the panel to show; `build` returns the prompt.
- **The result** (`TicketOutcome.parse`): the bot ends with `TICKET: KEY link`, `DUPLICATE: KEY link` or `FAILED: why`.
  Only a key in the project plus an https link on your Jira site pointing at that exact ticket counts as created.
- **Skill import** (`SkillStore.importSkill`, `SkillSources.find`, `ensureTicketSkill`): copies a skill folder from
  where it is on this Mac (`~/.claude/skills`, Claude's synced skills, the Claude plugin folder) into the library.
- **Guard** (`TicketGuard`, `GuardRulesFile.config(extraAlwaysAllowed:)`, `write(variant:)`).

### Decisions
- **The skill is not in the repository.** `biscuit-jira-tickets` is company process and this repo is public, so
  it's copied at run time from the Mac it's on. An import never replaces a skill: the same text is left alone, a
  different one is refused.
- **Selected text is untrusted.** It comes from emails and web pages. The prompt fences it between markers with a
  random nonce (moved if the text contains it), says it's data and that instructions in it aren't to be followed,
  and tells the bot to write [redacted] for secrets. Hidden and direction-changing characters are stripped first.
- **Nothing is cut silently.** Over the cap, the selection is cut at a word boundary, the panel warns and the prompt
  tells the bot the selection is partial.
- **A duplicate check comes before the create**, so a retry after a lost reply doesn't make a second ticket.
- **Settings are out of reach of bots**, in the data folder with the other protected files (the guard and the
  sandbox both refuse writes), because the approval mode is a safety setting. The assignee list sits there too.
- **The guard used to let Jira creates through without a card.** `createJiraIssue` splits into create, jira and issue,
  and none counted as sending. Ask me first would have asked about nothing. Writing to an issue or ticket tool
  (create, edit, update, transition, assign, add, link, move, write) now counts as sending, for any connector.
- **File without asking only loosens the create call.** It adds an Always-allow for the Jira create tool in a
  separate rules file (`rules/<bot>.ticket.json`); a push, any other send, a Never rule, a locked-down bot and the
  "Always allow for writes" switch all still apply.
- **A wrong project key is an error, not a fallback**, so a typo can't file tickets in the wrong project.

Tests: 35 new (`TicketTests`, `SkillImportTests`): settings, cleaning and cutting, the fence, the result checks
(including look-alike hosts, other tickets' links and credentials in links), the guard in both modes, a bot's attempts to
edit the settings file, and the importer (copy, no replace, links refused, nothing left behind, finding it on disk).
