# Claude issue workflow

Claude Code picks up GitHub issues labeled `claude`, builds them with tests, gets an independent code review from a second agent, and opens a PR. You review and merge. Claude never merges.

## How it works

Each run (hourly, on the Mac Mini):

1. **Read the queue.** Takes the lowest numbered open issue labeled `claude` that isn't already in progress, waiting, or done.
2. **Ask if needed.** If the issue is unclear, Claude posts numbered questions (with suggested defaults) as a comment, labels it `claude:needs-info`, and stops.
3. **Build it** on `claude/issue-<n>-<slug>`, with new tests.
4. **Test everything** with the full `xcodebuild test` suite.
5. **Independent review** by the `code-reviewer` agent, which hasn't seen the work being written.
6. **Fix and retest** anything the review flagged.
7. **Open a PR** and label the issue `claude:pr-open`.

One issue per run. If it gets stuck (tests won't pass after 3 tries), it opens a draft PR or comments, and labels the issue `claude:blocked`.

| Label | Meaning | Your move |
| --- | --- | --- |
| `claude` | Queued | Add it when an issue is ready |
| `claude:in-progress` | Being worked | Nothing |
| `claude:needs-info` | Claude asked questions | Answer in a comment, then **remove this label** |
| `claude:pr-open` | PR waiting | Review and merge (or comment) |
| `claude:blocked` | Stuck | Read the comment or draft PR |

The pieces:

- `CLAUDE.md`: project context and rules
- `.claude/skills/work-issues/SKILL.md`: the workflow above
- `.claude/agents/code-reviewer.md`: the reviewer
- `.claude/settings.json`: what Claude may run unattended; force push, pushing to `main`, and `gh pr merge` are denied
- `scripts/claude/`: label setup, the worker script, and the launchd job

## One time setup on the Mac Mini

1. **Tools.** Xcode 27 with command line tools selected, [Claude Code](https://code.claude.com/docs/en/overview) installed and logged in (`claude`, then `/login`), and GitHub CLI logged in (`gh auth login`).

2. **A dedicated clone** for the worker, separate from the copy you edit by hand:

   ```bash
   mkdir -p ~/claude-worker && cd ~/claude-worker
   git clone https://github.com/linuxaid/MRCommandCenter.git
   cd MRCommandCenter
   ```

3. **Labels:**

   ```bash
   bash scripts/claude/setup-labels.sh
   ```

4. **Confirm tests pass from the command line** in that clone (this also catches signing prompts before Claude hits them):

   ```bash
   xcodebuild -project "MR Command Center.xcodeproj" -scheme "MR Command Center" -destination "platform=macOS" test 2>&1 | tail -5
   ```

5. **Try one run by hand** and watch it:

   ```bash
   bash scripts/claude/claude-worker.sh
   tail -f ~/Library/Logs/mrcc-claude-worker/*.log
   ```

6. **Schedule it** once a manual run looks right:

   ```bash
   mkdir -p ~/Library/Logs/mrcc-claude-worker
   cp scripts/claude/com.weinnotes.mrcc-claude-worker.plist ~/Library/LaunchAgents/
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.weinnotes.mrcc-claude-worker.plist
   ```

   Run it now without waiting an hour: `launchctl kickstart gui/$(id -u)/com.weinnotes.mrcc-claude-worker`
   Stop it: `launchctl bootout gui/$(id -u)/com.weinnotes.mrcc-claude-worker`

   It's a LaunchAgent, so it only runs while you're logged in on the Mini. That's intentional: some tests render views and need a GUI session.

## Interactive use

From any clone, `claude` then `/work-issues` runs the same workflow with you watching. Good for the first few issues.

## Knobs

- **Spend cap per run:** `CLAUDE_WORKER_MAX_BUDGET_USD` (default 10).
- **Frequency:** `StartInterval` in the plist (seconds).
- **What Claude may run:** `.claude/settings.json`. Unattended runs use `--permission-mode dontAsk`, so anything not on the allow list is denied rather than prompted.
- **Pulling in worker updates:** the worker clone pulls `main` at the start of every run, so merged changes to the skill or settings take effect automatically.
