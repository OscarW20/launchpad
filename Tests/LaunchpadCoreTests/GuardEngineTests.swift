import XCTest
@testable import LaunchpadCore

/// The guard's classifier and lock rules: the Biscuit Bots guard self-test, as XCTest cases. Biscuit-specific
/// checks (its own chat server, its app folder, GitLab / Freshdesk / Cosmos DB / adb commands) are replaced
/// by generic ones (trusted servers, Launchpad's data folder, your own "change" patterns, deploy commands).
final class GuardEngineTests: XCTestCase {
    let home = NSHomeDirectory()
    var root: String { home + "/My Launchpad" }
    var folder: String { root + "/bots/scout" }
    var shared: String { root + "/groups/team" }
    var skill: String { folder + "/.claude/skills/my-weekly-report-1a2b3c" }
    var dataDir: String { root + "/.launchpad" }
    var rulesDir: String { dataDir + "/rules" }

    var config: GuardConfig {
        var c = GuardConfig()
        c.bot = "Scout"
        c.folder = folder
        c.roots = [folder, shared]
        c.locked = [skill]
        c.protected = [rulesDir, dataDir + "/answers", folder + "/.claude/settings.json"]
        c.trustedServers = ["launchpad"]
        return c
    }
    /// Everything allowed, to see that locks and Launchpad's files hold anyway.
    var open: GuardConfig {
        var c = config
        c.rules = ["send": "allow", "delete": "allow", "spend": "allow", "change": "allow", "shell": "allow", "computer": "allow"]
        return c
    }
    var never: GuardConfig {
        var c = config
        c.rules = ["send": "never", "delete": "never", "spend": "never", "computer": "never"]
        return c
    }
    let deny = GuardVerdict.deny("")

    func check(_ got: GuardVerdict, _ want: GuardVerdict, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let same: Bool
        switch (got, want) {
        case (.pass, .pass), (.deny, .deny): same = true
        case (.ask(let a, _), .ask(let b, _)): same = a == b
        default: same = false
        }
        XCTAssertTrue(same, "\(name): got \(got), want \(want)", file: file, line: line)
    }
    func bash(_ c: String, cwd: String? = nil, _ cfg: GuardConfig? = nil) -> GuardVerdict {
        GuardEngine.decide(tool: "Bash", input: ["command": c], cwd: cwd ?? folder, config: cfg ?? config)
    }
    func tool(_ t: String, _ input: [String: Any] = [:], _ cfg: GuardConfig? = nil) -> GuardVerdict {
        GuardEngine.decide(tool: t, input: input, cwd: folder, config: cfg ?? config)
    }

    // MARK: Defaults

    func testDefaultsAskBeforeSendingDeletingSpending() {
        check(tool("mcp__slack__slack_post_message", ["channel_id": "C1", "text": "hi"]), .ask(.send, ""), "slack post asks")
        check(tool("mcp__slack__chat_postMessage"), .ask(.send, ""), "camelCase postMessage asks")
        check(tool("mcp__teams__send_channel_message"), .ask(.send, ""), "teams send asks")
        check(tool("mcp__gmail__send_email"), .ask(.send, ""), "gmail send asks")
        check(tool("mcp__atlassian__addCommentToJiraIssue"), .ask(.send, ""), "jira comment asks")
        check(tool("mcp__figma__post_comment"), .ask(.send, ""), "figma comment asks")
        check(tool("mcp__github__add_issue_comment"), .ask(.send, ""), "github issue comment asks")
        check(tool("mcp__github__create_pull_request"), .ask(.send, ""), "github PR create asks")
        check(tool("mcp__github__pull_request_review_write"), .ask(.send, ""), "github review asks")
        check(tool("mcp__slack__slack_get_channel_history"), .pass, "slack read passes")
        check(tool("mcp__github__list_comments"), .pass, "list comments passes")
        check(tool("mcp__postgres__query"), .pass, "postgres query passes")
        check(tool("mcp__launchpad__send_sticker", ["name": "happy"]), .pass, "trusted server's tools pass")
        check(bash("gh pr comment 12 --body 'looks good'"), .ask(.send, ""), "gh pr comment asks")
        check(bash("curl -X POST https://hooks.slack.com/services/T/B/x -d '{}'"), .ask(.send, ""), "slack webhook asks")
        check(tool("mcp__notion__delete_page"), .ask(.delete, ""), "delete tool asks")
        check(tool("mcp__stripe__create_payment_link"), .ask(.spend, ""), "stripe tool asks")
        check(tool("mcp__stripe__list_customers"), .pass, "stripe read passes")
        check(tool("mcp__shop__buy_item"), .ask(.spend, ""), "buy tool asks")
        check(bash("stripe payment_intents create --amount 500"), .ask(.spend, ""), "stripe cli asks")
        check(tool("mcp__computer__click"), .ask(.computer, ""), "computer use asks by default (Launchpad default)")
        check(tool("Read", ["file_path": "/etc/hosts"]), .pass, "plain read passes")
    }

    // MARK: Deleting

    func testDeletingIsFreeInsideItsFolderAndAsksElsewhere() {
        check(bash("rm -rf build"), .pass, "rm in own folder passes")
        check(bash("rm '\(folder)/notes.txt'"), .pass, "rm own absolute passes")
        check(bash("rm ~/Desktop/report.pdf"), .ask(.delete, ""), "rm in home asks")
        check(bash("rm -rf ../Other"), .ask(.delete, ""), "rm escaping folder asks")
        check(bash("cd /Users/x/Projects && rm -rf dist"), .ask(.delete, ""), "rm after cd asks")
        check(bash("rm -rf $TARGET"), .ask(.delete, ""), "rm with variable asks")
        check(bash("sqlite3 app.db 'DELETE FROM users'"), .ask(.delete, ""), "sql delete asks")
        check(bash("git push origin --delete old-branch"), .ask(.delete, ""), "remote branch delete asks")
        check(bash("find . -name '*.tmp' -delete"), .pass, "find -delete inside passes")
        check(bash("rm notes.txt", cwd: home + "/Documents"), .ask(.delete, ""), "rm from outside cwd asks")
        check(bash("npm run format"), .pass, "format word isn't rm")
    }

    // MARK: Shell outside the folder

    func testShellOutsideTheFolder() {
        var shellAsk = config; shellAsk.rules["shell"] = "ask"
        check(bash("ls ~/Documents"), .pass, "shell outside allowed by default")
        check(bash("ls ~/Documents", shellAsk), .ask(.shell, ""), "shell outside asks when set")
        check(bash("swift build && ls Sources/", shellAsk), .pass, "shell inside passes when set")
        check(bash("/usr/bin/python3 script.py > /tmp/out.txt 2>/dev/null", shellAsk), .pass, "shell system tools pass")
        check(bash("cp report.md '\(shared)/report.md'", shellAsk), .pass, "shell shared folder passes")
        check(bash("sudo softwareupdate -l", shellAsk), .ask(.shell, ""), "shell sudo asks")
        check(bash("cat ../Other/notes.md", shellAsk), .ask(.shell, ""), "shell parent asks")
        check(bash("curl -s https://example.com/a/b", shellAsk), .pass, "shell url passes")
    }

    // MARK: Never and Always allow

    func testNeverDeniesAndAlwaysAllowIsPerTool() {
        check(tool("mcp__slack__slack_post_message", [:], never), deny, "never send denies")
        check(tool("mcp__computer__screenshot", [:], never), deny, "never computer denies")
        check(bash("rm ~/Desktop/x", never), deny, "never delete denies")
        var allowSend = config; allowSend.rules["send"] = "allow"
        check(tool("mcp__slack__slack_post_message", [:], allowSend), .pass, "allow send passes")
        var always = config; always.alwaysAllowed = ["send:mcp__slack__slack_post_message"]
        check(tool("mcp__slack__slack_post_message", [:], always), .pass, "always allowed passes")
        check(tool("mcp__gmail__send_email", [:], always), .ask(.send, ""), "always allowed is per tool")
    }

    func testNeverBeatsAlwaysAndNoAlwaysForTheTerminal() {
        var neverButAlways = never; neverButAlways.alwaysAllowed = ["delete:Bash", "send:mcp__slack__slack_post_message"]
        check(bash("rm -rf ~/Documents", neverButAlways), deny, "never beats always allow (bash)")
        check(tool("mcp__slack__slack_post_message", [:], neverButAlways), deny, "never beats always allow (tool)")
        var bashAlways = config; bashAlways.alwaysAllowed = ["delete:Bash"]
        check(bash("rm ~/Desktop/report.pdf", bashAlways), .ask(.delete, ""), "always allow ignored for Terminal")
    }

    func testAlwaysAllowOffForWrites() {
        var noAlways = config
        noAlways.alwaysAllowed = ["send:mcp__slack__slack_post_message", "computer:mcp__computer__click"]
        check(tool("mcp__slack__slack_post_message", [:], noAlways), .pass, "always allow works by default")
        noAlways.noAlwaysForWrites = true
        check(tool("mcp__slack__slack_post_message", [:], noAlways), .ask(.send, ""), "always allow off for writes asks")
        noAlways.rules = ["computer": "ask"]
        check(tool("mcp__computer__click", [:], noAlways), .pass, "always allow still on for non-writes")
        var c = noAlways; c.noAlwaysForWrites = false; c.rules = ["send": "never"]
        check(tool("mcp__slack__slack_post_message", [:], c), deny, "never beats always")
    }

    // MARK: Locks and Launchpad's own files

    func testLockedSkillsAndProtectedFiles() {
        check(tool("Write", ["file_path": skill + "/SKILL.md"], open), deny, "write locked skill denied")
        check(tool("Edit", ["file_path": ".claude/skills/my-weekly-report-1a2b3c/SKILL.md"], open), deny, "edit locked skill relative denied")
        check(tool("Edit", ["file_path": folder + "/.claude/skills/my-other-9z9z9z/SKILL.md"], open), .pass, "edit unlocked skill passes")
        check(bash("sed -i '' 's/a/b/' .claude/skills/my-weekly-report-1a2b3c/SKILL.md", open), deny, "sed on locked skill denied")
        check(bash("echo hi >> \(skill)/SKILL.md", open), deny, "echo into locked skill denied")
        check(bash("cat .claude/skills/my-weekly-report-1a2b3c/SKILL.md", open), .pass, "cat locked skill passes")
        check(bash("rm -rf .claude/skills/my-weekly-report-1a2b3c", open), deny, "rm locked skill denied")
        check(tool("Write", ["file_path": rulesDir + "/abc.json"], open), deny, "rules file denied")
        check(tool("Edit", ["file_path": folder + "/.claude/settings.json"], open), deny, "bot settings denied")
        check(bash("python3 -c 'open(\"\(rulesDir)/x.json\",\"w\")'", open), deny, "rules via bash denied")
    }

    func testLaunchpadDataFolderInAnySpelling() {
        for c in ["echo '{}' > ~/My\\ Launchpad/.launchpad/rules/x.json",
                  "D=\"$HOME/My Launchpad/.launchpad\"; echo '{}' > \"$D/rules/x.json\"",
                  "echo '{}' > \"$X/rules/x.json\"", "cp /tmp/r.json ~/MY\\ LAUNCHPAD/.LAUNCHPAD/RULES/x.json",
                  "mv ~/My\\ Launchpad/.launchpad/rules ~/old", "chmod -R u+w ~/My*Launchpad/.launch*/rules",
                  "echo '[]' > ~/My\\ Launchpad/.launchpad/locked-skills.json",
                  "echo approve > ~/My\\ Launchpad/.launchpad/answers/abc.answer",
                  "python3 -c 'open(\"\(dataDir)/answers/x.answer\",\"w\").write(\"approve\")'",
                  "cp evil.json .claude/settings.local.json", "echo '{}' > ~/.claude/settings.json"] {
            check(bash(c, open), deny, "data folder: \(c)")
        }
        check(tool("Write", ["file_path": rulesDir.lowercased() + "/x.json"], open), deny, "rules folder lower case (Write)")
        check(tool("Write", ["file_path": folder + "/.CLAUDE/Settings.json"], open), deny, "settings other case (Write)")
        check(tool("Write", ["file_path": home + "/elsewhere/.claude/settings.local.json"], open), deny, "any Claude settings file (Write)")
        check(tool("Write", ["file_path": "/opt/x/managed-settings.json"], open), deny, "managed settings (Write)")
        check(bash("sed -i '' 's/a/b/' ~/Code/launchpad/Sources/launchpad-guard/main.swift", open), .pass, "editing Launchpad's source elsewhere passes")
        check(bash("cat ~/My\\ Launchpad/.launchpad/usage.json", open), .pass, "reading Launchpad's data passes")
    }

    func testLockedSkillOtherSpellings() {
        for c in ["cd .claude/skills; echo hi > my-weekly-report-1a2b3c/SKILL.md",
                  "cd .claude/skills/my-weekly-report-1a2b3c && echo hi > SKILL.md",
                  "chmod +w .claude/skills/my-week*/SKILL.md && echo x >> .claude/skills/my-week*/SKILL.md",
                  "echo hi > .claude/skills/./my-weekly-report-1a2b3c/SKILL.md", "echo hi > .claude//skills/my-weekly-report-1a2b3c/SKILL.md",
                  "rm -rf .claude", "rm -rf .claude/skills", "mv .claude/skills /tmp/x", "find . -name SKILL.md -delete",
                  "echo hi > .CLAUDE/Skills/MY-WEEKLY-REPORT-1A2B3C/SKILL.md", "bash -c 'cd .claude/skills; echo x > my-weekly-report-1a2b3c/SKILL.md'"] {
            check(bash(c, open), deny, "locked skill: \(c)")
        }
        check(tool("Write", ["file_path": ".claude/skills/MY-WEEKLY-REPORT-1A2B3C/SKILL.md"], open), deny, "locked skill other case (Write)")
        check(bash("find . -name '*.tmp' -delete", open), .pass, "find -delete of other files passes")
        check(bash("cp ~/Downloads/a.png .", open), .pass, "copy into own folder passes")
    }

    // MARK: Bypasses

    func testDeleteHiddenBehindWrappersAndCode() {
        for c in ["sleep 1 & rm -rf ~/Documents/x", "\\rm -rf ~/Documents/x", "env rm -rf ~/Documents/x", "env -i FOO=1 rm -rf ~/x",
                  "nohup rm -rf ~/Documents/x", "nice -n 5 rm -rf ~/x", "time rm -rf ~/x", "timeout 5 rm -rf ~/x", "exec rm -rf ~/x",
                  "command rm -rf ~/x", "sudo -u root rm -rf /x", "X=1 rm -rf ~/x", "! rm -rf ~/x",
                  "echo $(rm -rf ~/Documents/x)", "echo \"$(rm -rf ~/x)\"", "echo `rm -rf ~/Documents/x`",
                  "bash -c 'rm -rf ~/Documents/x'", "sh -c \"rm -rf $HOME/Documents/x\"", "zsh -lc 'rm -rf ~/x'", "eval \"rm -rf ~/Documents/x\"",
                  "if true; then rm -rf ~/Documents/x; fi", "for f in a; do rm -rf ~/Documents/x; done", "{ rm -rf ~/Documents/x; }",
                  "(rm -rf ~/x)", "true && rm -rf ~/x", "false || rm -rf ~/x", "ls | xargs rm", "find ~/Documents -name x | xargs -n 1 rm",
                  "find ~/Documents -name x -execdir rm {} +", "find ~/Documents -name x -exec /bin/rm {} \\;",
                  "find ~/Documents -name x -exec sh -c 'rm \"$1\"' _ {} \\;", "find ~/Documents -name x -ok rm {} \\;",
                  "python3 -c \"import shutil; shutil.rmtree('/Users/x/Documents/x')\"", "python3 -c 'import os; os.remove(\"/x\")'",
                  "node -e \"require('fs').rmSync('/x',{recursive:true})\"", "ruby -e 'FileUtils.rm_rf(\"/x\")'", "perl -e 'unlink \"/x\"'",
                  "osascript -e 'tell application \"Finder\" to delete POSIX file \"/x\"'", "python3 - <<EOF\nimport os\nos.remove('/x')\nEOF",
                  "rsync -a --delete src/ ~/Documents/", "cd /Users/x && rm -rf dist", "rm -rf \"$(pwd)/../x\""] {
            check(bash(c, never), deny, "never delete: \(c)")
        }
        check(bash("nohup rm -rf ~/x"), .ask(.delete, ""), "delete asks by default: wrapped")
        check(bash("cd sub && rm -rf build"), .pass, "rm after cd inside own folder passes")
        check(bash("(cd sub; rm -f a.txt)"), .pass, "rm in subshell inside own folder passes")
        check(bash("echo 'rm -rf ~/x is dangerous'"), .pass, "echo mentioning rm passes")
        var shellAsk = config; shellAsk.rules["shell"] = "ask"
        check(bash("swift build 2>&1 | tail -5", shellAsk), .pass, "2>&1 isn't a file")
    }

    func testCdTricksWithShellNever() {
        var shellNever = config; shellNever.rules["shell"] = "never"
        for c in ["cd ..; cd ..; cat Documents/secret.txt", "cd && cat Documents/secret", "cd; cat Documents/secret",
                  "pushd ..;pushd ..;cat x", "cd -; cat x", "cd \"$(git rev-parse --show-toplevel)\" && ls", "cat ..;",
                  "ls ~/My\\ Launchpad/bots/other"] {
            check(bash(c, shellNever), deny, "never shell: \(c)")
        }
        check(bash("cd Sources && ls ..", shellNever), .pass, "cd inside then .. stays inside")
        check(bash("ls ~/My\\ Launchpad/bots/scout/notes", shellNever), .pass, "own folder with escaped spaces passes")
    }

    func testSymlinksOutOfTheFolder() throws {
        let fm = FileManager.default
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("lp-guard-\(UUID().uuidString)")
        defer { try? fm.removeItem(atPath: tmp) }
        let botDir = tmp + "/bot", away = tmp + "/away", linkedSkill = botDir + "/.claude/skills/linked-skill-9q9q"
        try fm.createDirectory(atPath: away, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: linkedSkill, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: botDir + "/docs", withDestinationPath: away)
        try fm.createSymbolicLink(atPath: botDir + "/shortcut", withDestinationPath: linkedSkill)
        var linked = GuardConfig()
        linked.bot = "Scout"; linked.folder = botDir; linked.roots = [botDir]; linked.locked = [linkedSkill]
        linked.rules = ["delete": "never"]
        func linkedBash(_ c: String) -> GuardVerdict { GuardEngine.decide(tool: "Bash", input: ["command": c], cwd: botDir, config: linked) }
        check(linkedBash("rm -rf docs/*"), deny, "rm through a symlink out of the folder")
        check(linkedBash("rm -rf docs/../away"), deny, "rm via .. after a symlink")
        check(linkedBash("rm -f notes.txt"), .pass, "rm a real file in the folder passes")
        check(GuardEngine.decide(tool: "Write", input: ["file_path": botDir + "/shortcut/SKILL.md"], cwd: botDir, config: linked), deny,
              "write a locked skill through a symlink")
        check(linkedBash("echo x > shortcut/SKILL.md"), deny, "echo into a locked skill through a symlink")
    }

    func testSendingTheOldClassifierMissed() {
        check(tool("mcp__slack__conversations_add_message", ["channel_id": "C1", "payload": "hi"]), .ask(.send, ""), "slack conversations_add_message asks")
        check(tool("mcp__linear__create_comment"), .ask(.send, ""), "linear create_comment asks")
        check(bash("curl -X POST -H \"Authorization: token $T\" https://api.github.com/repos/o/r/issues/1/comments -d '{\"body\":\"hi\"}'"), .ask(.send, ""), "curl POST to GitHub comments asks")
        check(bash("curl -s https://api.github.com/repos/o/r/issues/1/comments"), .pass, "curl GET from GitHub passes")
        check(tool("mcp__slack__slack_get_users"), .pass, "server-prefixed read passes")
        check(tool("mcp__slack__slack_get_message"), .pass, "server-prefixed message read passes")
        // Launchpad's own rule: any request that sends data off this computer.
        check(bash("curl -X POST https://api.example.com/x"), .ask(.send, ""), "curl POST anywhere asks")
        check(bash("curl -d 'a=1' https://api.example.com/x"), .ask(.send, ""), "curl -d asks")
        check(bash("curl -X POST http://localhost:3000/api"), .pass, "curl POST to localhost passes")
        check(bash("curl -D headers.txt https://example.com"), .pass, "curl -D (dump headers) isn't sending")
        check(bash("curl -fsSL https://example.com/install.sh -o i.sh"), .pass, "curl -f isn't a form")
    }

    // MARK: Change

    func testChangeAsksByDefault() {
        let change = GuardVerdict.ask(.change, "")
        check(bash("git push origin main"), change, "git push asks")
        check(bash("git push -f origin main"), change, "git push -f asks")
        check(bash("git -C repo push --force-with-lease"), change, "git -C push asks")
        check(bash("git reset --hard HEAD~3"), change, "git reset --hard asks")
        check(bash("git reset HEAD file.txt"), .pass, "git reset soft passes")
        check(bash("git status && git log -3"), .pass, "git status passes")
        // Deploying and publishing (Launchpad's old "deploy" kind).
        for c in ["vercel --prod --yes", "vercel deploy", "cd app && vercel", "npx netlify deploy --prod", "npm publish",
                  "docker push me/app", "kubectl apply -f k8s/", "npx supabase db push", "firebase deploy", "gh pr merge 3"] {
            check(bash(c), change, "deploy: \(c)")
        }
        for c in ["vercel env ls", "vercel login", "npm run build", "git commit -m x", "kubectl get pods", "npx playwright test"] {
            check(bash(c), .pass, "not a change: \(c)")
        }
        check(bash("vercel domains buy habits.app"), .ask(.spend, ""), "buying a domain is spending")
        check(tool("mcp__vercel__deploy_project"), change, "deploy tool asks")
        check(tool("mcp__supabase__apply_migration"), change, "migration tool asks")
    }

    func testYourOwnChangePatterns() {
        var custom = config
        custom.changePatterns = [#"\bterraform\s+(apply|destroy)\b"#, #"\bmyctl\s+release\b"#, #"(\bcurl\b)(?=.*internal\.example\.com)(?=.*-x\s*(post|put))"#]
        let change = GuardVerdict.ask(.change, "")
        check(bash("terraform apply -auto-approve", custom), change, "custom: terraform apply")
        check(bash("cd infra && terraform destroy", custom), change, "custom: terraform destroy after cd")
        check(bash("myctl release v2", custom), change, "custom: myctl release")
        check(bash("terraform plan", custom), .pass, "custom: terraform plan passes")
        check(bash("terraform apply"), .pass, "without the pattern it passes")
        var neverChange = custom; neverChange.rules["change"] = "never"
        check(bash("bash -c 'terraform apply'", neverChange), deny, "custom pattern with Never, even wrapped")
        // A pattern that doesn't compile is skipped, never crashes, and the editor can flag it.
        var broken = config; broken.changePatterns = ["(unclosed"]
        check(bash("ls", broken), .pass, "broken pattern is ignored")
        XCTAssertEqual(GuardEngine.invalidPatterns(["(unclosed", #"\bok\b"#]), ["(unclosed"])
    }

    // MARK: Approval card text and helpers

    func testCardShowsWhatNeedsTheOK() {
        let padding = String(repeating: "echo harmless; ", count: 40)
        guard case .ask(_, let detail) = bash(padding + "rm -rf ~/Documents/x") else { return XCTFail("long command should ask") }
        XCTAssertTrue(detail.hasPrefix("Needs your OK: rm -rf ~/Documents/x"), String(detail.prefix(120)))
        XCTAssertTrue(detail.contains(padding))
        XCTAssertTrue(GuardEngine.describe(tool: "Bash", input: ["command": String(repeating: "x", count: 5000)]).contains("more characters not shown"))
        XCTAssertEqual(GuardEngine.describe(tool: "mcp__slack__post", input: ["channel": "C1", "text": "hi\nthere"]), "channel: C1\ntext: hi there")
    }

    func testParserAndPathHelpers() {
        let parsed = ShellParser.parse("a 'b c' \"d $(e f)\" g\\ h > out 2>&1; i")
        XCTAssertEqual(parsed.map(\.words), [["e", "f"], ["a", "b c", "d $(…)", "g h"], ["i"]])
        XCTAssertEqual(parsed[1].outputs, ["out"])
        XCTAssertEqual(GuardEngine.words("chat_postMessage"), ["chat", "post", "message"])
        XCTAssertEqual(ShellPath.resolve("../b/./c", cwd: "/a/x"), "/a/b/c")
        XCTAssertTrue(ShellPath.inside("/private/tmp/x", "/tmp"))
        XCTAssertEqual(ShellParser.expand(ShellCommand(words: ["sudo", "-u", "root", "env", "A=1", "nice", "-n", "5", "rm", "x"], raw: ""), depth: 0).map(\.words), [["rm", "x"]])
        XCTAssertEqual(ShellParser.walk("cd a && cd $X && ls", cwd: "/w").map(\.1), ["/w", "/w/a", nil])
    }
}
