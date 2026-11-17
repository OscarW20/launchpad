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
    notes.md        the bot's own memory
    workspace/      where it does its work
  groups/<group-id>/group.json
  skills/<skill-id>/SKILL.md
  chats/<chat-id>.json    title, members, engine session per bot
  chats/<chat-id>.jsonl   message history
  connectors.json         MCP servers (no secrets)
```

The app watches these files, so you (or any agent) can add or edit a bot by hand and it shows up
straight away. If `CLAUDE.md` and `AGENTS.md` differ, the one edited most recently wins.

Set `LAUNCHPAD_HOME` to use a different folder (handy for trying things out).

## Code layout

- `Sources/LaunchpadCore`: everything that isn't UI. Bot and chat storage, the folder watcher,
  the engine runner (`Runner/`), stream parsers for both CLIs, plain-English errors, markdown blocks.
  Builds and tests on Linux too.
- `Sources/Launchpad`: the SwiftUI app.
- `Tests/LaunchpadCoreTests`: runner, parser, storage and markdown tests. Parser fixtures are real
  CLI output.

See [BUILD_LOG.md](BUILD_LOG.md) for what's built, decisions made, and what's next.
