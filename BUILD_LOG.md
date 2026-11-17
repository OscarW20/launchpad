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
