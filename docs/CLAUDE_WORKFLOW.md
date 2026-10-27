# Claude issue workflow

Claude Code picks up GitHub issues labeled `claude`, builds each with tests and an independent code review from a second agent, and gathers the finished ones into **one release per day**: one PR, merged once the full suite passes and no Blocking findings are left, then a GitHub release tagged with the date (`yy.m.d`, e.g. `26.10.27`). That tag is also the app's version, shown in the sidebar's bottom corner.

## How it works

Runs start hourly on the Mac Mini, but **only one release can happen per day**: if today's release (e.g. `26.10.27`) already exists, the run exits straight away. Otherwise a run:

1. **Opens today's release branch** `claude/release-<version>` from `main`.
2. **Works every eligible issue**, lowest number first (up to `CLAUDE_WORKER_MAX_ISSUES`). For each one:
   1. **Ask if needed.** If the issue is unclear, Claude posts numbered questions (with suggested defaults), labels it `claude:needs-info`, and moves on. It isn't in today's release.
   2. **Build it** on `claude/issue-<n>-<slug>` (branched from the release branch), with new tests.
   3. **Test everything** with the full `xcodebuild test` suite.
   4. **Independent review** by the `code-reviewer` agent, of just this issue's changes. Fix and retest what it flags.
   5. **Add it to the release** by merging the issue branch into the release branch. An issue that gets stuck stays out and is labeled `claude:blocked`; the rest carry on.
3. **Stamps the version** (`MARKETING_VERSION = <version>`) and runs the full suite on the whole release.
4. **Opens one PR** that closes every issue in it, labeled `claude:pr-open`.
5. **Merges it** if the suite passed on the final commit and no Blocking finding is left, then **publishes the GitHub release** `<version>` with one line per issue, and comments "Shipped in <version>" on each issue (plus anything worth checking by eye). Otherwise the PR stays open and its issues are labeled `claude:blocked`, and no release is made.

If nothing makes it into the release, there's no PR and no release, so the day is still free. While a run is going, the hourly trigger skips.

| Label | Meaning | Your move |
| --- | --- | --- |
| `claude` | Queued | Add it when an issue is ready |
| `claude:in-progress` | Being worked, or done and waiting for the rest of today's release | Nothing |
| `claude:needs-info` | Claude asked questions | Answer in a comment, then **remove this label** |
| `claude:pr-open` | In today's release PR, about to be merged | Nothing (if it stays open, see `claude:blocked`) |
| `claude:blocked` | Stuck | Read the comment or draft PR |

The pieces:

- `CLAUDE.md`: project context and rules
- `.claude/skills/work-issues/SKILL.md`: the workflow above
- `.claude/agents/code-reviewer.md`: the reviewer
- `.claude/settings.json`: what Claude may run unattended; `gh pr merge` and `gh release create` are allowed, while force push and pushing to `main` directly are denied
- `scripts/claude/`: label setup, the worker script, the launchd job, and `release-version.sh` / `set-version.sh` for the date version

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

From any clone, `claude` then `/work-issues` runs the same workflow with you watching: every eligible issue goes into today's release. `/work-issues 2` caps the release at two issues. Remember there's one release per day, so a hand run uses up the day's release too.

## Knobs

- **Issues per release:** `CLAUDE_WORKER_MAX_ISSUES` (default 5). Issues are worked one at a time, not in parallel; the rest wait for tomorrow.
- **Spend cap per run:** `CLAUDE_WORKER_MAX_BUDGET_USD` (default 10 × `MAX_ISSUES`).
- **Frequency:** `StartInterval` in the plist (seconds).
- **What Claude may run:** `.claude/settings.json`. Unattended runs use `--permission-mode dontAsk`, so anything not on the allow list is denied rather than prompted.
- **Pulling in worker updates:** the worker clone pulls `main` at the start of every run, so merged changes to the skill or settings take effect automatically.
