# Launchpad

A native macOS chat app for your personal AI team. You message bots like colleagues; each bot
runs on **Claude Code** (your Claude plan) or **Codex** (your ChatGPT plan), in its own folder.

Personal use only. No backend: everything lives in `~/Launchpad/`.

## Run it

Needs macOS 14+, Xcode 16 or later (or its command-line tools), and at least one of:

- Claude Code: `claude` on your PATH, signed in (`claude auth login`)
- Codex: `codex` on your PATH, signed in (`codex login`)

```bash
git clone https://github.com/OscarW20/launchpad.git
```

```bash
cd launchpad && swift run Launchpad
```

Or build a proper app bundle into `dist/Launchpad.app` and open it:

```bash
./scripts/make-app.sh --open
```

Run the tests:

```bash
swift test
```

The live tests talk to the real CLIs and use your plan, so they're opt-in:

```bash
LAUNCHPAD_LIVE_TESTS=1 swift test --filter LiveEngineTests
```

## Bots are folders

```
~/Launchpad/
  bots/<bot-id>/
    bot.json        name, emoji, colour, role, engine, model, permission, connectors, skills
    CLAUDE.md       instructions (Claude Code reads this)
    AGENTS.md       the same instructions (Codex reads this), kept in sync
    MEMORY.md       the bot's long-term memory, by topic (an old notes.md is imported once)
    workspace/      where it does its work
  groups/<group-id>/
    group.json      name, members, lead, rules, hand-off limit, skills, connectors
    SUMMARY.md      decisions, owners, open issues (kept by the lead)
    workspace/      the group's shared project folder
  skills/<skill-id>/SKILL.md
  chats/<chat-id>.json    title, members, engine session per bot
  chats/<chat-id>.jsonl   message history
  connectors.json         MCP servers (no secrets: those are in your Keychain)
  routines.json           scheduled and folder-triggered messages
  Shared/TEAM.md          team notes every bot reads
```

The app watches these files, so you (or any agent) can add or edit a bot by hand and it shows up
straight away. If `CLAUDE.md` and `AGENTS.md` differ, the one edited most recently wins.

Set `LAUNCHPAD_HOME` to use a different folder (handy for trying things out).

## What's in it

- **Chats** with any bot or group, streaming replies, a collapsible list of steps, Stop, and plain-English errors.
- **Bots** you create or **Hire** (Lead, Planner, Designer, Frontend, Backend, Tester, Reviewer, Shipper), or the whole
  **Dev team** with a `#build-and-ship` group in one click.
- **Groups**: the lead replies first and hands work out by @mention; members go one at a time (or in parallel when the
  lead says so); a hand-off limit pauses the team and asks you. **Ask everyone** gets a quick view from each member.
- **Skills** library (with Graphify one click away), given to bots or whole groups, plus **Teach a skill** from any chat.
- **Connectors** (MCP servers) per bot or group, secrets in the Keychain.
- **Chat tools** (in LaunchpadCore, app wiring in progress): bots react, send GIFs, run polls, ask tappable questions,
  share a plan with Start / Cancel before long tasks and set up routines, through the bundled `launchpad-chat` MCP server.
  Messages can be pinned, saved, edited, deleted and forwarded; files can be attached; chats export to Markdown.
- **Approval cards**: bots ask before deploying, sending, spending or deleting. For Claude Code bots this is enforced
  by a hook, not just requested.
- **Safety core** (in LaunchpadCore, app wiring in progress): per-bot permissions (Ask / Allow / Never for send, delete,
  spend, change, commands outside its folder, use your Mac), a guard that really reads shell commands, locked skills,
  the macOS sandbox with an optional lock-down, and undo for a bot's file changes.
- **Routines** on a schedule or when a file appears, and plan **usage** in the sidebar.
- **Marketplace**: 35 roles, 5 team packs, 41 skills and 40 app (MCP)
  presets with logos. See `CatalogRoles.swift`, `TeamPacks.swift`, `CatalogSkills.swift`, `ConnectorCatalog.swift`.

- **Memory**: each bot keeps `MEMORY.md` by topic. When a chat goes quiet, a cheap no-tools pass files lasting
  facts there (secrets redacted, size capped, daily limit per bot), and every change can be undone.

## Code layout

- `Sources/LaunchpadCore`: everything that isn't UI. Bot and chat storage, the folder watcher,
  the engine runner (`Runner/`), stream parsers for both CLIs, plain-English errors, markdown blocks.
  Builds and tests on Linux too.
- `Sources/Launchpad`: the SwiftUI app. `Resources/Logos` holds the app logos (Simple Icons, CC0, plus a few vendor icons).
- `Sources/launchpad-guard`: the approval hook Claude Code runs before shell commands and MCP tools.

- `Sources/Launchpad`: the SwiftUI app.
- `Sources/LaunchpadCore/Guard`: the permission guard (shell parser, rules engine, hook and approval handshake).
- `Sources/LaunchpadCore/Safety`: permissions model, sandbox profile, site gateway, snapshots for undo.
- `Sources/launchpad-guard`: the hook Claude Code runs before tool calls (`launchpad-guard hook <rules.json> …`).
- `Tests/LaunchpadCoreTests`: runner, parser, storage and markdown tests. Parser fixtures are real
  CLI output.

See [BUILD_LOG.md](BUILD_LOG.md) for what's built, decisions made, and what's next.
