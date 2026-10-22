---
name: work-issues
description: Work the GitHub issues labeled `claude` one after another, lowest number first: implement each with tests, get an independent code review, open a PR, and merge it once the suite passes and the review is clean. Issues that need answers get questions and are skipped. Use when asked to work the issue queue, or when run headless by the scheduled worker (`/work-issues once`).
---

# Work the issue queue

You are working GitHub issues end to end, usually unattended. Nobody is watching, so you cannot ask questions live. Questions go into the issue as a comment (step 3).

Work one issue at a time. When an issue is merged, asked about, or blocked, go back to step 1 for the next one, until no eligible issues are left (see "Next issue"). If this skill was invoked with the argument `once` (the scheduled worker does this), work exactly **one** issue and stop.

Use `gh` for all GitHub work. Repo: the `origin` remote of this checkout.

## Labels (the state machine)

| Label | Meaning |
| --- | --- |
| `claude` | Queued for Claude. Required on every issue Claude touches. |
| `claude:in-progress` | Claude is working it right now. |
| `claude:needs-info` | Claude asked questions in a comment. Waiting on a human. |
| `claude:pr-open` | A PR is open. Claude merges it once the suite passes and the review is clean; it stays open only if that didn't happen (see step 9). |
| `claude:blocked` | Claude got stuck (tests wouldn't pass, build broken, etc.). Needs a human. |

An issue is **eligible** when it is open, has `claude`, and has none of the other four labels. When a human answers questions, they remove `claude:needs-info`, which makes the issue eligible again.

## 0. Preflight

1. `git status --porcelain` must be empty. If not, stop and report: "Working tree not clean, not starting."
2. `git checkout main && git pull --ff-only`.
3. Make sure the five labels exist. If any is missing, stop and report that `scripts/claude/setup-labels.sh` needs to be run.

## 1. Pick the issue

1. List open issues labeled `claude`. Drop any that carry `claude:in-progress`, `claude:needs-info`, `claude:pr-open`, or `claude:blocked`.
2. Drop any issue that already has an open PR referencing it (`gh pr list --state open --search "<number> in:body"`).
3. Take the **lowest numbered** remaining issue. If none, report "No eligible issues" and stop. That is a normal, successful run.
4. Claim it: add `claude:in-progress` and comment: "Picking this up. I'll comment again when there's a PR or a question."

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

To ask: post one comment with numbered questions, each with your suggested default ("1. Should merged MRs open read only? I'd suggest read only, since actions don't apply."). Then remove `claude:in-progress`, add `claude:needs-info`, and **stop working this issue**. Do not start coding. Go to "Next issue".

## 4. Build it

1. `git checkout -b claude/issue-<n>-<short-slug>`.
2. Make the change. Follow `CLAUDE.md` conventions and the `PLAN.md` gotchas. Keep the diff focused on the issue; no drive-by refactors.
3. Write tests for the new behavior:
   - Swift Testing (`@Test`, `#expect`), in the matching folder under `MR Command Center Tests/`.
   - Reuse `Fixture`, `SpyGitLabClient`, `StubTransport`, `FakeReviewModel`.
   - For mostly-UI issues, extract the decision logic into a model and test the model. If something truly can only be checked by eye, say so in the PR under "Not verified by tests".
   - Each acceptance criterion from step 2 should map to at least one test where possible.

## 5. Test everything

Run the full suite with the command in `CLAUDE.md`. It passes only if it ends with `** TEST SUCCEEDED **`.

If it fails, fix and rerun. **After 3 failed attempts**, go to "If you get stuck".

## 6. Independent review

Launch the `code-reviewer` subagent. Give it the issue number, the issue title and acceptance criteria, and the branch name. Do not tell it how you think it went; let it judge the diff fresh.

It returns findings marked **Blocking**, **Should fix**, or **Nit**.

## 7. Address the review

1. Fix every **Blocking** and **Should fix** finding. Fix nits when cheap. If you disagree with a finding, leave it and explain why in the PR.
2. Rerun the full suite (step 5 rules apply).
3. If you changed more than a few lines, run `code-reviewer` once more. Maximum two review rounds.

## 8. Open the PR

1. Commit with a clear message referencing the issue (`Fix #<n>: ...`). Push the branch: `git push -u origin <branch>`.
2. `gh pr create --base main` with this body:

   ```markdown
   Closes #<n>

   ## What changed
   <2 to 5 bullets, plain language>

   ## Decisions I made
   <defaults you picked instead of asking, or "None">

   ## Tests
   <new and changed tests; confirm the full suite passed>

   ## Code review
   <what the reviewer flagged and what you did about each>

   ## Not verified by tests
   <anything that needs a human to look at, or "Nothing">
   ```

3. On the issue: remove `claude:in-progress`, add `claude:pr-open`, and comment with the PR link.

## 9. Merge

The owner has authorized Claude to merge its own PRs in this repo, under these conditions:

1. Merge only when **all** of these hold:
   - the full suite ended with `** TEST SUCCEEDED **` on the PR's final commit;
   - no **Blocking** review finding is left unfixed;
   - the PR is not a draft.

   Otherwise leave the PR open, comment on it saying why, label the issue `claude:blocked`, and go to "Next issue".
2. `gh pr merge <pr> --merge --delete-branch`. Never push to `main` directly and never force push.
3. If GitHub refuses because `main` moved (conflicts):
   1. Run `git fetch origin` and `git merge origin/main` on the branch, and resolve the conflicts.
   2. Rerun the full suite (step 5 rules), push, and try the merge once more.
   3. If it still can't merge, follow "If you get stuck".
4. Check that the issue closed (`Closes #<n>` does it). If it didn't, run `gh issue close <n>`. Remove `claude:pr-open`.
5. If the PR's "Not verified by tests" section isn't "Nothing", comment on the issue with that list, headed "Merged. Worth checking by hand next time you run the app:".
6. `git checkout main && git pull --ff-only`, so the next issue builds on this one.

## If you get stuck

Tests still failing after 3 attempts, the build is broken on `main`, or something unexpected blocks you:

1. If you have useful work, push the branch and open the PR as a **draft** (`gh pr create --draft`), explaining exactly what fails and what you tried.
2. Otherwise, comment on the issue with what happened.
3. Remove `claude:in-progress`, add `claude:blocked`, and go to "Next issue".
4. If `main` itself is broken (it doesn't build or its tests fail before you change anything), stop the whole run instead: every other issue would hit the same wall.

## Next issue

Unless invoked with `once`, go back to step 0 (preflight) and pick the next eligible issue. An issue you asked about, merged, or blocked is no longer eligible, so the queue always shrinks. Stop when step 1 finds no eligible issues, or if an issue you just handled is somehow still eligible (never work the same issue twice in one run).

## Final output

End the run with one short line per issue handled, for example:
- `#5: merged <url>`
- `#5: PR opened, not merged (Blocking finding left) <url>`
- `#5: asked 2 questions, waiting`
- `#5: blocked, tests failing in LayoutStressTests (draft PR <url>)`
- `No eligible issues`
