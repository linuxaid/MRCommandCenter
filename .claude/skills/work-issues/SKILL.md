---
name: work-issues
description: Work every GitHub issue labeled `claude` into one daily release, lowest number first: implement each with tests and an independent code review on its own branch, gather the finished ones on a release branch, open one PR, merge it once the suite passes and the reviews are clean, and publish a GitHub release tagged with today's date (yy.m.d) that is also the app's version. One release per day. Issues that need answers get questions and are skipped. Use when asked to work the issue queue, or when run headless by the scheduled worker.
---

# Work the issue queue into today's release

You are working GitHub issues end to end, usually unattended. Nobody is watching, so you cannot ask questions live. Questions go into the issue as a comment (step 3).

A run produces **at most one release**: every eligible issue is built on its own branch, the finished ones are merged into a release branch, and that branch ships as one PR and one GitHub release. The release tag is today's date as `yy.m.d` (for example `26.10.27`), and it is also the app's version. There can be **only one release per day**, so a run stops at once if today's release already exists.

Arguments: none means "every eligible issue". A number `N` (the scheduled worker passes one) means "at most N issues in this release".

Use `gh` for all GitHub work. Repo: the `origin` remote of this checkout.

## Labels (the state machine)

| Label | Meaning |
| --- | --- |
| `claude` | Queued for Claude. Required on every issue Claude touches. |
| `claude:in-progress` | Claude is working it right now (including: done and waiting on the rest of today's release). |
| `claude:needs-info` | Claude asked questions in a comment. Waiting on a human. |
| `claude:pr-open` | It's in today's release PR. Claude merges it once the suite passes and the reviews are clean; it stays open only if that didn't happen (see step 10). |
| `claude:blocked` | Claude got stuck (tests wouldn't pass, build broken, etc.). Needs a human. |

An issue is **eligible** when it is open, has `claude`, and has none of the other four labels. When a human answers questions, they remove `claude:needs-info`, which makes the issue eligible again.

## 0. Preflight

1. `git status --porcelain` must be empty. If not, stop and report: "Working tree not clean, not starting."
2. `git checkout main && git pull --ff-only`.
3. Make sure the five labels exist. If any is missing, stop and report that `scripts/claude/setup-labels.sh` needs to be run.
4. `VERSION=$(bash scripts/claude/release-version.sh)`. Use this one value for the whole run, even if the run goes past midnight.
5. If `gh release view <VERSION>` succeeds, or `git ls-remote --tags origin <VERSION>` prints anything, stop and report "Already released today (<VERSION>)". That is a normal, successful run.
6. Find the eligible issues (step 1, items 1 and 2). If there are none, report "No eligible issues" and stop. That is also a normal, successful run.
7. Create the release branch from `main`: `git checkout -b claude/release-<VERSION>`. If it already exists (an earlier run today stopped partway), check it out instead and keep what's on it.

## 1. Pick the next issue

1. List open issues labeled `claude`. Drop any that carry `claude:in-progress`, `claude:needs-info`, `claude:pr-open`, or `claude:blocked`.
2. Drop any issue that already has an open PR referencing it (`gh pr list --state open --search "<number> in:body"`).
3. Take the **lowest numbered** remaining issue. If none, or this release already holds N issues (when a number was given), go to step 8.
4. Claim it: add `claude:in-progress` and comment: "Picking this up for today's release (<VERSION>). I'll comment again when it ships or if I have a question."

## 2. Understand it

1. Read the issue body **and every comment** (`gh issue view <n> --comments`). Answers to earlier questions are in the comments.
2. Read `PLAN.md` (architecture and gotchas) and the code the issue touches. Find the existing tests for that area.
3. Write down, for yourself, the acceptance criteria: what observable behavior proves this is done.

## 3. Ask, if you need to

Ask instead of guessing when any of these is true:

- Two reasonable readings of the issue would produce noticeably different results.
- The change would remove or alter existing behavior the issue doesn't mention.
- It needs a product decision (wording, defaults, what happens in an edge case that matters).
- It needs something outside the repo: credentials, real accounts, a new dependency, entitlements, signing changes.

Do **not** ask about things you can settle by reading the code, or about small choices where any sensible default is fine. For those, pick, and say what you picked in the PR.

To ask: post one comment with numbered questions, each with your suggested default ("1. Should merged MRs open read only? I'd suggest read only, since actions don't apply."). Then remove `claude:in-progress`, add `claude:needs-info`, and **stop working this issue**. Do not start coding. Go back to step 1 for the next issue.

## 4. Build it

1. Branch from the release branch, not `main`, so each issue builds on the ones already in today's release: `git checkout claude/release-<VERSION> && git checkout -b claude/issue-<n>-<short-slug>`.
2. Make the change. Follow `CLAUDE.md` conventions and the `PLAN.md` gotchas. Keep the diff focused on the issue; no drive-by refactors. Don't touch `MARKETING_VERSION`; step 8 sets it.
3. Write tests for the new behavior:
   - Swift Testing (`@Test`, `#expect`), in the matching folder under `MR Command Center Tests/`.
   - Reuse `Fixture`, `SpyGitLabClient`, `StubTransport`, `FakeReviewModel`.
   - For mostly-UI issues, extract the decision logic into a model and test the model. If something truly can only be checked by eye, say so under "Not verified by tests".
   - Each acceptance criterion from step 2 should map to at least one test where possible.
4. Commit on the issue branch with a clear message referencing the issue (`Fix #<n>: ...`).

## 5. Test everything

Run the full suite with the command in `CLAUDE.md`. It passes only if it ends with `** TEST SUCCEEDED **`.

If it fails, fix and rerun. **After 3 failed attempts**, go to "If you get stuck".

## 6. Independent review

Launch the `code-reviewer` subagent. Give it the issue number, the issue title and acceptance criteria, the issue branch, and the **base branch `claude/release-<VERSION>`** (so it reviews only this issue's changes). Do not tell it how you think it went; let it judge the diff fresh.

It returns findings marked **Blocking**, **Should fix**, or **Nit**.

## 7. Address the review, then add it to the release

1. Fix every **Blocking** and **Should fix** finding. Fix nits when cheap. If you disagree with a finding, leave it and note why (it goes in the PR).
2. Rerun the full suite (step 5 rules apply).
3. If you changed more than a few lines, run `code-reviewer` once more. Maximum two review rounds.
4. If a **Blocking** finding is still left, treat the issue as stuck ("If you get stuck") so it stays out of the release.
5. Otherwise merge it into the release branch: `git checkout claude/release-<VERSION> && git merge --no-ff claude/issue-<n>-<short-slug>`. Keep `claude:in-progress` on the issue.
6. Keep notes for the PR: what changed, decisions you made, tests, what the reviewer flagged and what you did, and anything not verified by tests.
7. Go back to step 1 for the next issue.

## 8. Stamp the version and test the whole release

1. If no issue was merged into the release branch, there is nothing to ship: `git checkout main`, delete the local release branch (`git branch -d claude/release-<VERSION>`), and go to "Final output". No PR and no release, so today's release slot stays free.
2. On the release branch: `bash scripts/claude/set-version.sh <VERSION>`, then commit: `Release <VERSION>`.
3. Run the full suite on the release branch (step 5 rules). This catches issues that pass alone but break together. If it fails after 3 attempts, go to "If you get stuck" for the release as a whole.

## 9. Open the release PR

1. Push the release branch: `git push -u origin claude/release-<VERSION>`.
2. `gh pr create --base main --title "Release <VERSION>"` with this body, one `Closes` line and one section per issue in the release:

   ```markdown
   Closes #<n>
   Closes #<m>

   Release <VERSION>. The app version and the release tag are both <VERSION>.

   ## #<n>: <issue title>
   ### What changed
   <2 to 5 bullets, plain language>
   ### Decisions I made
   <defaults you picked instead of asking, or "None">
   ### Tests
   <new and changed tests>
   ### Code review
   <what the reviewer flagged and what you did about each>
   ### Not verified by tests
   <anything a human should look at, or "Nothing">

   ## #<m>: <issue title>
   ...

   ## Full suite
   <confirm it ended with ** TEST SUCCEEDED ** on the release branch's final commit>
   ```

3. On each issue in the release: remove `claude:in-progress`, add `claude:pr-open`, and comment with the PR link.

## 10. Merge and release

The owner has authorized Claude to merge its own release PRs and publish the release in this repo, under these conditions:

1. Merge only when **all** of these hold:
   - the full suite ended with `** TEST SUCCEEDED **` on the PR's final commit;
   - no **Blocking** review finding is left unfixed in any issue in the release;
   - the PR is not a draft;
   - today's release `<VERSION>` still doesn't exist (check again, as in preflight).

   Otherwise leave the PR open, comment on it saying why, label its issues `claude:blocked`, and go to "Final output".
2. `gh pr merge <pr> --merge --delete-branch`. Never push to `main` directly and never force push.
3. If GitHub refuses because `main` moved (conflicts):
   1. Run `git fetch origin` and `git merge origin/main` on the release branch, and resolve the conflicts. Keep `MARKETING_VERSION = <VERSION>`.
   2. Rerun the full suite (step 5 rules), push, and try the merge once more.
   3. If it still can't merge, follow "If you get stuck".
4. `git checkout main && git pull --ff-only`. Check that `MARKETING_VERSION` on `main` is `<VERSION>`.
5. Publish the release on the merge commit:

   ```bash
   gh release create <VERSION> --target "$(git rev-parse HEAD)" --title "<VERSION>" --notes "<notes>"
   ```

   The notes: one line per issue, `- #<n>: <issue title>`, then a line linking the PR. If this fails, comment on the PR with the error and report it; don't retry with a different tag.
6. For each issue in the release:
   1. Check that it closed (`Closes #<n>` does it). If it didn't, run `gh issue close <n>`.
   2. Remove `claude:pr-open`.
   3. Comment "Shipped in <VERSION>: <release URL>". If its "Not verified by tests" wasn't "Nothing", add that list, headed "Worth checking by hand next time you run the app:".
7. Delete the local issue branches that went into the release (`git branch -d claude/issue-<n>-<short-slug>`).

## If you get stuck

**One issue** stuck (tests still failing after 3 attempts, a Blocking finding you can't fix, or something unexpected):

1. Leave it out of the release: don't merge its branch into the release branch. If you already did, revert that merge on the release branch (`git revert -m 1 <merge commit>`).
2. If you have useful work, push the issue branch (`git push -u origin claude/issue-<n>-<short-slug>`) and say so in the comment.
3. Comment on the issue with what fails and what you tried.
4. Remove `claude:in-progress`, add `claude:blocked`, and go back to step 1 for the next issue. The rest of the release carries on.

**The whole release** stuck (the full suite fails on the release branch, or the PR can't merge):

1. Push the release branch and open the PR as a **draft** (`gh pr create --draft`), explaining exactly what fails and what you tried. Don't create a release.
2. Label every issue in it `claude:blocked` (removing `claude:in-progress` / `claude:pr-open`).

If `main` itself is broken (it doesn't build or its tests fail before you change anything), stop the whole run: every issue would hit the same wall.

## Final output

End the run with one line for the release and one per issue handled, for example:
- `Release 26.10.27: published <release url> (PR <url>)`
- `#5: shipped in 26.10.27`
- `#6: asked 2 questions, waiting`
- `#7: blocked, tests failing in LayoutStressTests (branch pushed)`
- `No eligible issues`
- `Already released today (26.10.27)`
