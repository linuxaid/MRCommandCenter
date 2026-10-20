# MR Command Center — Plan and Handoff

**Status (October 1, 2026, end of session 1):** Phases 1–7 are complete, plus several scope additions (listed below). **196 tests pass.** The app builds, runs in mock mode, and has been exercised against the real on-device model. It has **not** been run against a real GitLab or Jira instance yet.

**Session 2 (October 2, 2026):** testing with real data started.
- **Draft MRs are hidden by default.** The setting is `AccountSettings.showDraftMergeRequests`, toggled from View → Show Draft Merge Requests or the "N drafts hidden" link in the sidebar footer. `MergeRequestStore.mergeRequests` is the visible list; `reviewerMergeRequests` includes drafts, and Jira and static checks still run on it so toggling is instant. Phase 8 notifications should skip hidden drafts.
- **The Swift skill was rewritten:** concrete, checkable bug patterns (crashes, errors, memory, concurrency, SwiftUI, Codable), plus a "never flag" line. It's 514 real tokens of the shared 600-token budget, so another skill matching `*.swift` (or `*`) will usually be dropped. Unedited built-in skills upgrade on launch through `DefaultSkills.previousContents`. Not yet measured against real Swift MRs.
- **New: `VSCodeAPIExtension/`**, a VS Code extension that exposes Copilot's models through `vscode.lm` on a token-protected `127.0.0.1:52741` API (`/v1/health`, `/v1/models`, `/v1/chat`, `/v1/tokens`). 12 server tests pass and it packages to a `.vsix`, but it hasn't run inside VS Code yet. The app doesn't call it yet; the next step would be a `CopilotBridgeModel: ReviewLanguageModel` that asks for JSON instead of `@Generable` output. First, check that the work machine allows **Install from VSIX…**. The background is in the session 2 discussion: the on-device model gives poor comments (for example, on imports), and the work machine has only Copilot.

**Session 3 (October 20, 2026): command center redesign.** The main window is now an overseer's view, not a review tool.
- **Lanes:** every open MR (reviewing *or* authored; GitLab is asked for both lists) lands in exactly one lane: *Your move*, *Ready to merge*, *Merging on its own*, *In flight*, *Drafts*, with a one-sentence headline and who has the next move. Logic is pure and tested: `CommandCenter/MRSituation.swift`, `Readiness.swift`. "Your move" = someone replied in a thread you're in (or any open thread on your MR), your approval is needed and the author isn't blocked, or your own MR's pipeline failed / has conflicts.
- **Layout:** sidebar (Briefing, lanes with counts, Activity, Merge Rules) → triage list with a 4-segment readiness rail (CI · Approvals · Threads · Mergeable) → brief panel. The brief has a "What changed" file glance (sizes, static-check flags). **Review mode** (double-click a row, Return, ⌘↩, or Review Here) swaps the whole window for one MR: brief rail on the left, Changes / AI Review / Details on the right, ⌥⌘↑↓ to step through the queue, Esc back. No extra windows; `MRDetailView` is gone (`Features/CommandCenter/ReviewMode.swift`). Always light appearance; tokens in `Features/CommandCenter/Theme.swift`. The draft show/hide toggle is gone (drafts have a lane).
- **Activity:** `ActivityEvent` rows are recorded by diffing snapshots on each refresh (`ActivityDetector`): pushes, pipeline results, approvals, replies, conflicts, ready-to-merge, merged/closed, rule actions. Unseen activity shows a dot until you open the brief.
- **Merge rules:** `MergeRule` (filters: project/branch globs, labels, authors, only mine; requirements: threads, static checks, AI verdict, quiet period, max files; squash/delete branch). `CommandCenter.runRules()` runs after every refresh and calls `PUT …/merge` with `sha` pinned to the evaluated head. Master switch `AccountSettings.autoMergeEnabled` defaults **off** (dry run: reports "would merge" once per commit). When on, polling continues while the app is in the background. Needs an `api`-scope token. **Not yet tried against real GitLab.**
- **Approve and merge from the app** (the user can't otherwise): Approve / Revoke and Merge… in the brief, the review header, the row's context menu, and ⇧⌘A / ⇧⌘M. Approving sends `sha` (refused if the head moved); merging always goes through `MergeSheet`, which lists what isn't green, offers squash / delete branch (remembered), and "merge when the pipeline succeeds" while a pipeline runs. Logic is in `CommandCenter` (`approve`, `revokeApproval`, `merge`); failures show in the brief via `actionErrors`. Needs an `api`-scope token. **Not yet tried against real GitLab.**
- **Menu bar:** `MenuBarExtra` with the Your Move count (icon only when zero). The panel lists Your Move MRs (click opens the main window on that brief), a one-line summary of the other lanes, and refresh status. No actions and no notifications there (user's choice). Polling moved from `RootView` to `AppModel.startPolling()`, so it runs while the app is open even with the window closed; `AppDelegate` keeps the app alive after the window closes. The Dock icon stays.
- **Settings → General → "Keep this Mac awake while the app is open"** (`ActivityKeeper`, `AccountSettings.keepMacActive`): calls `IOPMAssertionDeclareUserActivity` every 60 s, which keeps the display on and prevents the idle lock. Pauses on sleep, closed lid (`AppleClamshellState`), and screen lock; remembered across launches; the menu bar footer shows "Keeping Mac awake". **It does not keep Teams presence green:** measured, it doesn't reset input idle time. A zero-move `CGEvent` would, but posting events needs Accessibility, which is locked on the user's work Mac (also confirmed: without it the event is silently dropped). The user originally wanted Teams presence; this is what's possible.
- 229 tests pass.

**Start the next session here:** read "Where we are" and "Next steps" below. Everything after those sections is reference.

---

## Where we are

| Phase | State | Notes |
|---|---|---|
| 1. Skeleton, Keychain, Accounts | ✅ Done | Tokens in Keychain; connection details in SwiftData; Test Connection for GitLab and Jira |
| 2. GitLab client + reviewer MR list | ✅ Done | Pagination, 401/403/429/offline, caching by `updated_at`, polling, ⌘R |
| 3. MR detail: Overview + Changes | ✅ Done | Unified and side-by-side diffs, every special case (binary, renames, collapsed, overflow) |
| 4. Static checks | ✅ Done | 12 checks; diff checks cached per head SHA + settings fingerprint |
| 5. On-device AI review | ✅ Done | Per-file sessions, token budgeting and splitting, merge step, skills |
| 6. Evaluation tooling | ✅ Done | Prompt editor, 👍/👎 feedback, eval sets, batch compare, JSON export |
| 7. Jira | ✅ Done (mock only) | Story vs. code in the AI review, status and priority checks, setup preview |
| 8. Notifications + polish | ⬜ Not started | AI summary posting was already pulled forward |

### Verified so far
- **Unit and integration tests:** 196 tests, all against mock GitLab/Jira and a fake model.
- **Layout regression test:** the window-resize stress test in `UI/LayoutStressTests`.
- **Real on-device model (live runs):**
  - The 6-case mock eval set ran on two prompt versions with 0 errors.
  - Story-vs-code checks caught all 3 planted story/code mismatches.
- **Visual checks:** off-screen renders of the main screens, in light and dark.

### Not verified yet (needs the user's real environment)
- **Real GitLab** (self-managed, 15.7+):
  - reviewer list, diffs and discussions
  - posting inline comments and summary threads (needs a token with the `api` scope)
  - whether approving an MR bumps its `updated_at`; if not, approval counts go stale between other changes
- **Real Jira:** the acceptance-criteria field ID, how the team writes criteria, passing-status names. Use Settings → Accounts → **Check the setup** to preview an issue.
- **Hands-on use:** the user hasn't clicked through the toolbar, menus or keyboard shortcuts in the running app since the later changes.

### Known issue: AI verdict calibration
On the mock eval set, verdict agreement is **1/6** for both prompt versions. The model reliably finds the real problems (recall 4/5 and 5/5) but rates almost everything "Likely problem", because it adds speculative high-severity concerns. Prompt wording alone didn't fix it.

---

## Next steps (in priority order)

1. **Verification pass (recommended next).** For each high or medium concern, run a short follow-up session: "Is this a real bug in the shown diff? yes/no". Drop or downgrade the concerns that fail, then recompute the verdict.
   - Make it a setting so it can be compared with and without.
   - It costs about 2–3 seconds per concern.
   - Measure it in the Evaluation window against `v1` on the mock eval set. The goal is to raise verdict agreement above 1/6 without losing recall.
2. **Real-environment check** (when the user has access):
   - Connect GitLab and confirm the list, diffs and comments work.
   - Approve an MR and check whether the count updates after ⌘R.
   - Preview 2–3 Jira issues with the setup tool, and set the acceptance-criteria field ID.
3. **Build a real eval set.** 5–10 real MRs with known answers, including some clean ones. The mock set is only a smoke test.
4. **Phase 8:**
   - macOS notifications, as optional toggles that already exist in `AccountSettings`: a new MR assigned for review, and a failed pipeline on an MR you're reviewing (reviewer MRs only, per the user's choice).
   - `RefreshOutcome` already reports `newMergeRequestKeys` and `newlyFailedPipelineKeys`; ignore it on the initial load.
   - Then an accessibility pass (VoiceOver labels exist; test with VoiceOver), Dynamic Type, and a final light/dark review.
5. **Optional, smaller items:**
   - "Post all AI comments…" with checkboxes in one preview
   - resolving threads from the app
   - a release-version check (deferred: the user hasn't defined what "correct" means yet)
   - syntax highlighting in diffs
   - an Evaluations-framework test target that loads the JSON export

### Open questions for the user
- Should approvals be fetched on every refresh? This depends on the `updated_at` check in "Not verified yet".
- Should missing approvals stay a **warning**, or become a failure?
- **Release version check:** what makes a fix version "correct" (target branch, milestone, a configured list)? Skipped for now.
- Raise the minimum macOS to 27 if everyone runs it? That would drop the macOS 26.x error-mapping branch, which can't be exercised on this Mac.

---

## How to work on this project

- **Open:** `MR Command Center.xcodeproj` (Xcode 27). Scheme: `MR Command Center`. Its Run action passes `-UseMockData`, which the user has ticked; untick it to use real accounts.
- **Build and test from the command line:**

  ```bash
  xcodebuild -project "MR Command Center.xcodeproj" -scheme "MR Command Center" -destination "platform=macOS" test
  ```

- **Mock mode (`-UseMockData`):**
  - mock GitLab with 8 MRs, rich diffs, discussion threads and Jira issues
  - an in-memory database and in-memory tokens; comment posting is enabled since nothing real is touched
  - the **real** on-device model when it's available
- **Git:** the repo is on `main` with one commit (`first commit`), covering everything through phase 7 plus the scope additions. `AI Coding Pilot Brief.pdf` is untracked (a manager brief; not part of the app).
- **Signing:** team `3BR8562V2D`, automatic. Bundle ID `com.weinnotes.MRCommandCenter`.
- **Local data:** `~/Library/Containers/com.weinnotes.MRCommandCenter/Data/Library/Application Support/default.store`. Tokens are in the Keychain under service `com.weinnotes.MRCommandCenter.tokens`.

### Gotchas learned in session 1
- **SwiftData lifetime:** keep a reference to the `ModelContainer` (or the `AppModel` that owns it) for as long as models are used. A `ModelContext` alone doesn't retain its container, and tests that dropped the `AppModel` crashed. Services hold the container for this reason.
- **AppKit layout loops:** the original crash with every panel open came from content-dependent minimum widths, a `Grid` in Overview, `HSplitView` in Changes, and SwiftUI's `.inspector`. Two changes fixed it:
  - The detail column has a fixed minimum width.
  - The inspector is a custom panel (`InspectorPanel`) inside the detail column, not `.inspector`.

  `LayoutStressTests` guards this; keep it passing.
- **`FlowLayout`** must report the width it actually uses, never echo the proposal.
- **Double quotes break the on-device model's structured output.** When it copies `"` from code (for example `loading="lazy"`), the JSON string ends early and you get "GeneratedContent does not contain a property…". `QuoteSafety` sends code with single quotes plus a note in the instructions. In a live comparison that parsed 10/10 files, versus 9/10 unchanged and 8/10 with a full-width quote. Parse failures also retry once with sampling.
- **Wrapped code hyphenates** unless the text is marked `.typesettingLanguage(.code)` (the `zxx` language).
- **`\r\n`** is one Swift `Character`. Split diffs with `whereSeparator: \.isNewline`, not `"\n"`.
- **Main-actor default isolation:** network types, DTOs and `@Generable` types must be `nonisolated`. `Regex` isn't `Sendable`, so secret rules are compiled per scan.
- **Off-screen snapshots for visual checks:** the user declined screen-control access, so the screens were checked by rendering them off-screen. The method:
  - Render with `NSHostingView` + `cacheDisplay` in a test, and print the PNG as base64 into the log. The sandbox blocks reading the test host's container.
  - Paint an opaque background first.
  - The sidebar's vibrancy and the toolbar don't capture correctly.

---

## Architecture (as built)

```
MR Command Center/
  App/          MRCommandCenterApp (main Window, Evaluation Window ⇧⌘E, Settings), AppModel, AppCommands, AppDependencies
  Core/         HTTP (HTTPClient: retry/429/offline, pagination, JSON decoding), Keychain (SecretStore), Logging (os.Logger), ClientFactory
  GitLab/       GitLabAPI, LiveGitLabClient, MockGitLabClient + MockDiffs + MockDiscussions, DTO/
  Jira/         JiraAPI, LiveJiraClient, MockJiraClient (+ MockJiraData), JiraAuth, JSONValue, ADFRenderer + AcceptanceCriteriaExtractor, JiraKeyExtractor, DTO/
  Diff/         UnifiedDiffParser, DiffFile/MRDiff, SideBySide, ThreadPlacement
  Checks/       CheckModels, StaticChecks (pure), PatternScanner, TestFileClassifier
  AIReview/     ReviewEngine, ReviewModel (OnDeviceReviewModel, tools, error mapping), PromptBuilder, ModelOutputs (@Generable),
                ReviewResults, ModelAvailability, AIReviewService, AIConcernPlacement (+ AICommentFormatter), SummaryPoster, QuoteSafety, Skills/
  Evaluation/   EvalService, EvalMetrics (pure), ExportService
  Sync/         MergeRequestStore, CachePolicy (pure), DiffService, DiscussionService, StaticCheckService, JiraService
  Persistence/  AppModelContainer, Models/ (AccountSettings, TrackedMR, DiffSnapshot, StaticCheckSnapshot, JiraCheck,
                ReviewSkill, PromptVersion, AIReviewRun/FileReviewRecord/ConcernRecord, EvalCase/EvalBatch)
  Features/     Root (RootView, InspectorPanel), Sidebar, Detail/{Overview, Changes, AIReview, StaticChecksSection},
                Evaluation, Settings/{Accounts, General, Checks, Skills, AI Review, Prompts}, Shared
MR Command Center Tests/   Swift Testing; Support/ (StubTransport, SpyGitLabClient, SpyJiraClient, FakeReviewModel), Fixtures/
```

**Data flow.**
1. `AppModel.refresh(trigger)` calls `MergeRequestStore.refresh`, then `JiraService.refresh`, then `StaticCheckService.evaluateMissing`.
2. The AI review (`AIReviewService.start`) gathers its inputs: the diff (`DiffService`), static findings, the story context (`JiraService`), enabled skills and the active `PromptVersion`.
3. It hands those to `ReviewEngine`, which is pure and model-agnostic.
4. The results are saved as `AIReviewRun` → `FileReviewRecord` → `ConcernRecord`.

**Caching rules**, all in `CachePolicy` and tested:
- MR details are refetched only when `updated_at` changed; an active pipeline is re-polled on its own.
- Diffs and diff checks run once per head SHA. Diff checks also rerun when the check settings change.
- An AI review runs only when the head SHA or prompt version changed; "Rerun" is explicit.
- A Jira issue in a passing status is skipped on automatic refreshes; manual refreshes always refetch.

**Model seam.** `ReviewLanguageModel` has two implementations: `OnDeviceReviewModel` (Foundation Models) and `FakeReviewModel` (tests). `AppDependencies.reviewModel` and `.modelStatus` are injectable.

---

## Scope changes from the original spec (all at the user's request)

- **Inline diff comments:**
  - Threads appear on their lines, with outdated, off-diff and orphaned groups.
  - You can start new threads and reply. Posting needs the "Allow posting comments" setting and an `api`-scope token.
- **AI concerns as diff comments:**
  - They appear in purple with an "AI" label, and can be dismissed.
  - "Post to GitLab…" opens an editable preview. The text always starts with "_Comment generated via MR Command Center_ 😃", and each concern can be posted only once.
- **AI summary thread on the MR:** a resolvable thread with the verdict, rationale, open concerns and static checks. It's offered when there are issues, once per run.
- **AI workflow:**
  - The toolbar has Review with AI / Rerun / Cancel on every tab, and the inspector toggle sits after the segmented control.
  - The sidebar shows an AI verdict badge above the title, with an open-comment count.
- **Review skills:** per-language guidance (6 starters), matched by globs. Settings → Skills: edit with versions, enable or disable, import and export `.md`, test a path. They share a 600-token budget per file, and runs record the skill versions they used.
- **Jira scope:** the review compares the code against the whole story (summary, description and acceptance criteria). A priority check passes when a priority is set and isn't a placeholder; the release-version check is deferred and fix versions are display-only. Settings → Accounts has a setup preview.
- **Labels:** GitLab labels are shown in their colors in the sidebar and Overview.

## Decisions

- **Minimum macOS 26.4, built with the macOS 27 SDK.** `tokenCount(for:)` first appears in 26.4. Errors from both 26.x (`GenerationError`) and 27 (`LanguageModelError`) are mapped.
- **Swift 6.** Code runs on the main actor by default, Swift Testing is used, and there are no third-party dependencies.
- **Project:** a hand-made `.xcodeproj` that picks up the source folders automatically, with a shared scheme and a hosted test target.
- **GitLab:** self-managed, 15.7 or later (paginated `/diffs`). The reviewer list uses `reviewer_id`.
- **Sandbox entitlements:** outgoing network, plus read-write access to files you pick (for skill import/export and the JSON export).
- **Apple's Evaluations framework** only works inside test targets, so the evaluation tooling is built into the app; a test target that uses the framework is optional.
- **AI defaults:** deterministic (greedy) output, files reviewed one at a time, the file-reading tool off. Eval batches never use tools.
- **Posting to GitLab:** always previewed and confirmed, always attributed, and gated by the setting. The app never edits Jira issues. It approves only when you click Approve, and merges only when you confirm a merge or a merge rule fires with the master switch on, always at the commit that was shown or evaluated.
