# Claude issue workflow

Claude Code picks up GitHub issues labeled `claude`, builds them with tests, gets an independent code review from a second agent, opens a PR, and merges it once the full suite passes and the review has no Blocking findings left. Then it moves on to the next issue.

## How it works

Each run (hourly, on the Mac Mini) works up to 3 issues, one after another. Each issue goes through:

1. **Read the queue.** Takes the lowest numbered open issue labeled `claude` that isn't already in progress, waiting, or done.
2. **Ask if needed.** If the issue is unclear, Claude posts numbered questions (with suggested defaults) as a comment, labels it `claude:needs-info`, and moves on to the next issue.
3. **Build it** on `claude/issue-<n>-<slug>`, with new tests.
4. **Test everything** with the full `xcodebuild test` suite.
5. **Independent review** by the `code-reviewer` agent, which hasn't seen the work being written.
6. **Fix and retest** anything the review flagged.
7. **Open a PR** and label the issue `claude:pr-open`.
8. **Merge it** (`gh pr merge --merge --delete-branch`) if the suite passed on the final commit and no Blocking finding is left. Anything a human should still check by eye is posted on the closed issue. Otherwise the PR stays open and the issue is labeled `claude:blocked`.

The run stops early when the queue is empty, when a pass fails, or when a pass finishes without taking an issue off the queue (so it never repeats one). While a run is going, the hourly trigger skips. If an issue gets stuck (tests won't pass after 3 tries), it opens a draft PR or comments, and labels the issue `claude:blocked`.

| Label | Meaning | Your move |
| --- | --- | --- |
| `claude` | Queued | Add it when an issue is ready |
| `claude:in-progress` | Being worked | Nothing |
| `claude:needs-info` | Claude asked questions | Answer in a comment, then **remove this label** |
| `claude:pr-open` | PR open, about to be merged | Nothing (if it stays open, see `claude:blocked`) |
| `claude:blocked` | Stuck | Read the comment or draft PR |

The pieces:

- `CLAUDE.md`: project context and rules
- `.claude/skills/work-issues/SKILL.md`: the workflow above
- `.claude/agents/code-reviewer.md`: the reviewer
- `.claude/settings.json`: what Claude may run unattended; `gh pr merge` is allowed, while force push and pushing to `main` directly are denied
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

From any clone, `claude` then `/work-issues` runs the same workflow with you watching. It keeps going, merging each PR and asking questions where needed, until no eligible issues are left. `/work-issues once` does a single issue.

## Knobs

- **Issues per run:** `CLAUDE_WORKER_MAX_ISSUES` (default 3). Issues are worked one at a time, not in parallel.
- **Spend cap per issue:** `CLAUDE_WORKER_MAX_BUDGET_USD` (default 10), so a run can spend up to `MAX_ISSUES` times this.
- **Frequency:** `StartInterval` in the plist (seconds).
- **What Claude may run:** `.claude/settings.json`. Unattended runs use `--permission-mode dontAsk`, so anything not on the allow list is denied rather than prompted.
- **Pulling in worker updates:** the worker clone pulls `main` at the start of every run, so merged changes to the skill or settings take effect automatically.
