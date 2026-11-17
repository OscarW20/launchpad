#!/usr/bin/env python3
"""Fills a Launchpad folder with demo bots, a group and chats (for screenshots).
Usage: LAUNCHPAD_HOME=/tmp/demo python3 scripts/demo-data.py"""
import json, os, datetime
root = os.environ["LAUNCHPAD_HOME"]
now = datetime.datetime.now(datetime.timezone.utc)
def t(mins): return (now - datetime.timedelta(minutes=mins)).strftime("%Y-%m-%dT%H:%M:%SZ")
def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(data if isinstance(data, str) else json.dumps(data, indent=2))
bots = [
    ("frontend", "Frontend", "🖥️", "#6C9BD2", "Frontend engineer (Next.js, React, Tailwind)", "claude"),
    ("reviewer", "Reviewer", "🔍", "#A38CD9", "Code reviewer giving a second opinion", "codex"),
    ("shipper", "Shipper", "🚀", "#E9C46A", "Release engineer (Vercel)", "claude"),
    ("lead", "Lead", "🧭", "#E8735A", "Team lead who plans and coordinates", "claude"),
    ("writer", "Writer", "✍️", "#8DB580", "Writer for docs and launch posts", "claude"),
    ("researcher", "Researcher", "🔬", "#4FA3A5", "Researcher who digs into anything", "claude"),
]
for bid, name, emoji, colour, role, engine in bots:
    d = f"{root}/bots/{bid}"
    write(f"{d}/bot.json", {"id": bid, "name": name, "emoji": emoji, "colour": colour, "role": role,
                            "engine": engine, "permission": "edit-workspace", "connectors": [], "skills": [],
                            "createdAt": t(600)})
    write(f"{d}/CLAUDE.md", f"# {emoji} {name}\n\nYou are {name}, {role}.\n")
    write(f"{d}/AGENTS.md", f"# {emoji} {name}\n\nYou are {name}, {role}.\n")
    write(f"{d}/MEMORY.md", f"# {name}'s memory\n")
    os.makedirs(f"{d}/workspace", exist_ok=True)
write(f"{root}/groups/build-and-ship/group.json", {"id": "build-and-ship", "name": "build-and-ship", "emoji": "🛠️",
      "members": ["lead", "frontend", "reviewer", "shipper"], "lead": "lead", "rules": "Ask before deploying.",
      "handoffLimit": 3, "skills": [], "connectors": [], "createdAt": t(600)})
write(f"{root}/groups/build-and-ship/SUMMARY.md", "# #build-and-ship: summary\n")
def chat(cid, title, kind, updated, preview, msgs, bot=None, group=None):
    meta = {"id": cid, "title": title, "kind": kind, "sessions": {}, "createdAt": t(500), "updatedAt": t(updated),
            "lastPreview": preview}
    if bot: meta["botId"] = bot
    if group: meta["groupId"] = group
    write(f"{root}/chats/{cid}.json", meta)
    write(f"{root}/chats/{cid}.jsonl", "".join(json.dumps(m) + "\n" for m in msgs))
def msg(mid, role, mins, text, bot=None, **extra):
    m = {"id": mid, "role": role, "text": text, "steps": [], "status": "done", "createdAt": t(mins)}
    if bot: m["botId"] = bot
    m.update(extra); return m
chat("c-frontend", "Frontend", "bot", 2, "Done. Login page is live on preview…", [
    msg("m1", "user", 12, "Build the sign-in page with Google and deploy a preview"),
    msg("m2", "bot", 8, "Done. The sign-in page uses **Supabase Auth** with Google, and the session survives a refresh. "
        "I've added the redirect URL to `.env.example`.\n\n```ts\nawait supabase.auth.signInWithOAuth({ provider: 'google' })\n```",
        bot="frontend", steps=[
            {"id": "s1", "tool": "Read", "title": "Read SPEC.md", "status": "succeeded"},
            {"id": "s2", "tool": "Edit", "title": "Edited app/login/page.tsx", "status": "succeeded"},
            {"id": "s3", "tool": "Bash", "title": "Ran `npm run build`", "status": "succeeded"}]),
    msg("m3", "user", 6, "Great, ship a preview please"),
    msg("m4", "bot", 4, "Build is green. Ready to deploy a preview to Vercel.", bot="frontend",
        approval={"action": "deploy habit-tracker to a Vercel preview", "status": "pending"}),
], bot="frontend")
chat("c-group", "#build-and-ship", "group", 20, "Lead: Plan's ready for your OK", [
    msg("g1", "user", 40, "Build a habit tracker with Google sign-in and deploy it"),
    msg("g2", "bot", 35, "Plan: spec → screens → Supabase tables (RLS on) → UI → tests → review → deploy.", bot="lead"),
], group="build-and-ship")
chat("c-reviewer", "Reviewer", "bot", 70, "Ship after fixes: 2 RLS gaps", [
    msg("r1", "bot", 70, "Ship after fixes: 2 RLS gaps", bot="reviewer")], bot="reviewer")
chat("c-shipper", "Shipper", "bot", 140, "Waiting for your approval", [
    msg("p1", "bot", 140, "Waiting for your approval", bot="shipper")], bot="shipper")
chat("c-writer", "Writer", "bot", 300, "", [], bot="writer")
print("demo data in", root)
