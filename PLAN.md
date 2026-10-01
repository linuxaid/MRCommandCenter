# MR Command Center — Build Plan

Status: **Phase 7 complete.** Next: Phase 8 (notifications, polish) or the verification pass.

## Platform decisions

- **Build SDK:** macOS 27.0 SDK (Xcode 27.0, installed on this machine).
- **Minimum macOS: 26.4.** Checked against the SDK's FoundationModels interface:
  - `SystemLanguageModel.tokenCount(for:)` (prompt, instructions, tools, schema, transcript) first appears in **26.4**.
  - `SystemLanguageModel.contextSize` is back-deployed to 26.0, so it doesn't limit the choice.
  - 26.4 is the lowest version that has both APIs the spec requires.
  - Cost: macOS 27 replaces `LanguageModelSession.GenerationError` with the new `LanguageModelError`, which adds `contextSizeExceeded(contextSize:tokenCount:)`, `timeout`, `rateLimited` and more. A small `ReviewFailure` mapping layer handles both. I can only exercise the 27 path on this Mac, so the 26.x branch will be compile-checked but not run. If everyone who will run this is on 27, I'd raise the minimum to 27 and delete that branch.
- **Swift 6 language mode** with strict concurrency. Swift Testing (`@Test`) for unit tests.
- **No third-party runtime dependencies.** Project generation tool: see open question 1.

## Apple's Evaluations framework: verdict

The framework is `Evaluations.framework`. It ships in Xcode's `Platforms/MacOSX.platform/Developer/Library/Frameworks`, next to XCTest and Testing, not in the SDK. Its `EvaluationTrait` is a Swift Testing `TestTrait`. That makes it a **test-time framework that can't be linked into the shipping app**. So:

- The **in-app** eval tooling (eval sets, batch rerun, compare table, feedback, export) is built directly.
- Optional in phase 6: an `MRCommandCenterEvals` test target that uses `Evaluations`. It loads an eval set exported from the app through `JSONLoader`, runs the same `ReviewEngine`, and reports aggregate metrics in Xcode's test report. I'll confirm the API fits when I get there.

## Project structure

```
MR Command Center/
  project.yml                      (if XcodeGen; .xcodeproj is generated and committed)
  MRCommandCenter/
    App/            MRCommandCenterApp (WindowGroup + Settings scene), AppModel (@Observable, @MainActor), Commands
    Core/           Keychain (SecretStore protocol, KeychainSecretStore, InMemorySecretStore),
                    HTTP (HTTPTransport protocol, pagination, 401/403/429 handling, Retry-After), Log (os.Logger)
    GitLab/         GitLabAPI protocol, LiveGitLabClient (actor), MockGitLabClient, DTOs
    Jira/           JiraAPI protocol, JiraAuth { cloudBasic(email, token), dataCenterBearer(token) },
                    LiveJiraClient, Mock, JiraKeyExtractor, AcceptanceCriteriaParser (ADF → text)
    Persistence/    @Model types, ModelContainer setup, PreviewData
    Sync/           RefreshCoordinator, CachePolicy (pure functions: refetch details? rerun AI? refetch Jira?)
    Diff/           UnifiedDiffParser (hunks, old/new line numbers), DiffFile model
    Checks/         StaticChecks (pure), PatternScanner (secrets, debug output, TODO/FIXME)
    AIReview/       ModelAvailability, @Generable outputs, PromptBuilder (token budgeting/hunk splitting),
                    ReviewEngine (actor; per-file sessions, concurrency limit, cancel), MergeStep,
                    Tools (FetchFileContentTool, SurroundingLinesTool), TranscriptRecorder, ReviewFailure
    Evaluation/     EvalSnapshotter, BatchRunner, ComparisonReport, JSONExporter
    Features/       Sidebar, Detail/{Overview, Changes (DiffView), AIReview}, Inspector,
                    Settings/{Accounts, Prompts, Checks, AI}, Eval/{EvalSets, Compare}, Onboarding
    Resources/      Assets, MRCommandCenter.entitlements (app-sandbox + network.client only)
  MRCommandCenterTests/            Swift Testing + Fixtures/*.json (GitLab and Jira responses)
  MRCommandCenterEvals/            (phase 6, optional) Evaluations-framework target
```

The core types are UI-free and pure where possible: CachePolicy, StaticChecks, JiraKeyExtractor, UnifiedDiffParser and PromptBuilder budgeting. That makes the required unit tests straightforward.

## Data model (SwiftData) — changes from the spec

| Model | Notes / changes |
|---|---|
| `AccountSettings` | Singleton row. Holds everything in the spec, plus: `jiraDeployment` (cloud / dataCenter), the **Keychain account identifiers** (not tokens), `aiConcurrencyLimit` (default 1), `aiToolsEnabled`, `debugPatterns` (configurable list), `testFileGlobs` / `sourceFileGlobs`, `postCommentsEnabled`, notification toggles, `activePromptVersionID`. |
| `TrackedMR` | As specified. Also: `isDraft`, `hasConflicts`, `labels`, `descriptionText`, `detailsFetchedAtUpdatedAt`, and `isInReviewerList`. When an MR leaves the reviewer list it is kept but hidden, so runs and eval cases stay intact. |
| `DiffSnapshot` *(new)* | Diff files for one `(MR, headSHA)`: parsed files encoded as `Data`, plus overflow and collapsed flags. Fetched lazily (Changes tab or AI run) and reused by eval snapshots. |
| `StaticCheckSnapshot` *(new)* | Static check results cached per head SHA, as the spec requires. |
| `JiraCheck` | As specified, plus `summary`, `issueType`, `assignee` and `lastStatusCategory`. |
| `PromptVersion` | Holds **two** instruction texts: `fileInstructions` (per-file sessions) and `mergeInstructions` (verdict session). Both are versioned together. |
| `AIReviewRun` | As specified, plus: `status` (running / completed / cancelled / failed), the `mrProjectID` / `mrIID` copy (survives MR deletion), an optional `evalCase` and `evalBatch`, and `verdictFeedback` + `verdictNote`. |
| `FileFinding` | As specified. The **file path is filled in by code, not generated by the model**, which avoids hallucinated paths. Also stores `partCount` (for hunk-split files), `errorKind`, token counts and latency per file, the exact instructions and prompt sent, and the tool-call log. |
| `ConcernRecord` *(new)* | Split out of `FileFinding` so each concern has an identity for 👍/👎 + note. |
| `EvalCase` *(new)* | MR identity, `headSHA`, `expectedVerdict`, `expectedConcerns` ([file, description]), and a **snapshot** of the diff, the Jira summary/AC and the static flags. Also caches any full-file contents the tool fetched, so later runs are reproducible. |
| `EvalBatch` *(new)* | One run of the eval set against a single `PromptVersion`. Its runs feed the comparison table. |

Arrays and enums are stored as encoded `Data` with typed accessors. SwiftData's composite Codable attributes are still fragile with migrations, and this sidesteps that.

## Sync and caching rules

- Every refresh fetches the reviewer list: `GET /merge_requests?state=opened&scope=all&reviewer_id=<me>`, paginated. It's cheap.
- Details, approvals and discussions are refetched **only if `updated_at` changed**.
  - **Caveat to verify on your instance:** a pipeline finishing doesn't always bump MR `updated_at`. While the cached head pipeline is non-terminal (running or pending), I'll also refetch just the head pipeline on each poll. That's one cheap call per active MR.
- Diffs are fetched lazily per head SHA through `/projects/:id/merge_requests/:iid/diffs` (paginated). The `overflow` flag and per-file `collapsed` / `too_large` flags each get a clear message and an "Open in browser" link.
- AI review runs only when `headSHA` ≠ the last *successful* run's SHA for the *active prompt version*. The UI shows "Reviewed at `abc1234`" and an explicit **Rerun** button.
- 401/403 shows a banner with "Fix token" (opens Accounts). 429 sleeps for `Retry-After`, then retries, at most N times. When offline (`URLError.notConnectedToInternet` etc.), the app shows cached data and an "Offline — showing data from <time>" banner.

## AI review design

1. **Availability.** `SystemLanguageModel.default.availability` is checked at launch and before every run. Each unavailable reason gets its own explanation (Apple Intelligence off, device not eligible, model downloading). Everything else in the app works without the model.
2. **Per-file sessions.** Binary and deleted-only files are skipped and recorded as skipped. The input is: the instructions, then the Jira summary + AC, or an explicit "No acceptance criteria available (Jira not connected)", then the file's static flags, then diff hunks with new-side line numbers.
3. **Token budget.** The budget is `contextSize − tokenCount(instructions) − tokenCount(schema) − tokenCount(tools) − response reserve`. If a file doesn't fit, its hunks are packed greedily into parts, one session per part. A single hunk that's too big on its own is split by lines. The parts' findings are merged deterministically (concerns concatenated and deduplicated, confidence = minimum).
4. **Generation options.** Default to **greedy sampling** so eval runs are reproducible. Temperature is configurable in the AI settings.
5. **Merge step.** A fresh session receives the compact per-file findings (not the diffs) plus the AC, and generates `MRVerdict`.
6. **Concurrency.** A TaskGroup with a configurable limit (default 1). Per-file progress is streamed to the UI, and **Cancel** cancels the group.
7. **Errors are per file.** Context exceeded, guardrail, unsupported language, refusal and timeout each mark only that file failed. The merge step is told which files couldn't be reviewed.
8. **Tools (flag).** `fetch_file_content(path)` at the head SHA and `surrounding_lines(path, line, radius)`. Every call is logged into the transcript and the inspector.

`@Generable` outputs (sketch):

```swift
@Generable struct FileFindingOutput {
  var summary: String
  var meetsCriteria: CriteriaMatch          // yes / partially / no / unclear
  @Guide(.maximumCount(5)) var concerns: [ConcernOutput]
  var confidence: Confidence                // low / medium / high
}
@Generable struct ConcernOutput { var lineHint: String; var severity: Severity; var explanation: String }
@Generable struct MRVerdictOutput {
  var status: VerdictStatus                 // looksGood / needsHumanReview / likelyProblem
  var criteriaCoverage: String
  @Guide(.maximumCount(5)) var topConcerns: [String]
  var rationale: String
}
```

## Evaluation tooling

- **Inspector.** Per file or MR run: the exact instructions and prompt, the full transcript including tool calls, token counts (input, output, total, and context size), latency, and the raw structured output as JSON.
- **Prompt versions.** An editor for both instruction texts. *Save as new version* is the only way to change one, so versions are immutable once runs reference them. An active-version picker. A seeded `v1` default.
- **Feedback.** 👍/👎 + note on every concern and on the verdict.
- **Eval set.** "Add to eval set" on any MR at its current SHA. It asks for the expected verdict and expected concerns, then snapshots diff, Jira and static flags.
- **Batch and compare.** Pick a prompt version and run every eval case against its snapshot. The comparison table has one row per prompt version and these columns:
  - verdict agreement %
  - helpful / wrong concerns (from feedback on that batch's runs)
  - **expected-concern recall**: an automatic proxy, counting an expected concern as hit when the model raised a concern on that file
  - average latency
  - average tokens
  - error count
- **Export.** JSON of runs, findings, concerns, feedback, prompt versions and eval cases, through `NSSavePanel` (sandbox user-selected-file access is read-write only for the chosen file). The same format is what the Evaluations test target loads.

> Note: Export through a save panel needs the `com.apple.security.files.user-selected.read-write` entitlement, on top of outgoing network. That's the only addition to "network only," and it's limited to files you pick. OK?

## Build order (app stays runnable after each phase)

1. **Skeleton.** XcodeGen/project, entitlements, `@Observable` AppModel, `SecretStore`/Keychain wrapper and tests, SwiftData container, Accounts screen (settings in SwiftData, tokens in Keychain, test-connection buttons, scope hints, update/remove), onboarding redirect, empty three-column shell.
2. **GitLab.** Client protocol, live and mock clients, DTO decoding tests with fixtures, pagination/401/429/offline, reviewer MR list with the status line, CachePolicy and its tests, auto poll + ⌘R, last-refreshed time, next/previous MR, ⌘O.
3. **Detail.** Overview section, Changes section with the diff parser and its tests, unified diff view, large/binary/renamed/new/deleted/collapsed/overflow handling, lazy diff caching. Side-by-side view and syntax highlighting are stretch goals.
4. **Static checks.** GitLab-based checks plus the pattern scanner and tests, cached per SHA, shown prominently in Overview and the sidebar. Jira checks show "Pending (Jira not configured)".
5. **AI review.** Availability UI, the `@Generable` types, PromptBuilder with token budgeting and splitting, ReviewEngine with concurrency, cancel and per-file errors, the merge step, the AI Review tab, ⌘⇧R, "Reviewed at sha" / Rerun. The tools are behind a flag.
6. **Evaluation.** Inspector, prompt version editor, feedback, eval sets with snapshots, batch runner, compare table, JSON export. Optionally the Evaluations test target.
7. **Jira.** Client (Cloud Basic; protocol ready for DC Bearer), key extraction and its tests, AC field with description fallback, passing-status caching, AC fed into the AI review, Jira checks lit up.
8. **Polish.** Opt-in "Post AI summary as comment" (preview + confirm, `api` scope hint), notifications (new review request, pipeline failed), accessibility pass, light/dark, Dynamic Type.

At the end of each phase I build with `xcodebuild`, run the tests, launch the app, and screenshot it to verify. Then I summarize what was built, what's stubbed, and what I need from you.

## Scope changes

- **Inline diff comments (added after phase 3, at your request).** Diff threads are shown on their lines. Comments left on an older version go in an "Outdated" group, comments on lines outside the shown hunks get their own group, and comments on files no longer in the diff are flagged. You can **start new inline threads and reply** to existing ones. Posting sits behind Settings → Accounts → "Allow posting comments" (off by default) and needs a token with the `api` scope. This extends the spec's original "read-only except the AI summary comment" rule. Resolving threads, editing, and suggestions are not in scope.

- **AI concerns as diff comments (added after phase 5, at your request).** Concerns from the latest AI review at the current head show inline in the Changes diff, in purple with an "AI" label, and you can hide them. Concerns whose line can't be matched are grouped at the top of the file. "Post to GitLab…" opens an editable preview and posts only on confirmation. The body always starts with "_Comment generated via MR Command Center_ 😃", which is re-added if edited out. Each concern records that it was posted, so it can't be posted twice. Posting uses the same "Allow posting comments" setting and `api` scope as inline comments.
- **AI workflow polish (after phase 5).**
  - A "Review with AI" / "Rerun" / "Cancel" button in the toolbar on every tab; the inspector toggle sits after the segmented control.
  - AI comments can be dismissed. "Open" means not posted and not dismissed, and the sidebar chip shows the open count ("AI: needs review · 2 open").
  - "Post Summary to GitLab…" posts the verdict, rationale, open concerns and static checks as a resolvable thread on the MR. It's attributed, uses an editable preview, posts once per run, and is only offered when there are issues. This brings forward the spec's phase 8 "Post AI summary as MR comment".
- **Jira scope (phase 7, per your answers).**
  - The AI review compares the code against the whole story: summary, description and acceptance criteria.
  - A **priority check** passes when a priority is set and isn't a placeholder like "None". It uses the standard field by default, or a configurable custom field ID.
  - **No release-version check for now.** Fix versions are only displayed in the Overview.
  - **Setup check:** Settings → Accounts → "Check the setup" previews an issue and suggests custom field IDs.
- **Review skills (added in phase 5, at your request).** These are language and area guidance files (Python, TypeScript, Swift, Go, Terraform and SQL to start). They're added to the model's instructions for files whose path matches the skill's globs. They're managed in Settings → Skills:
  - Create and edit skills; every save creates a new version.
  - Enable or disable them; delete them.
  - Import and export them as `.md` files with a `name` / `applies_to` header.
  - Restore the starter set, and test which skills a path matches.
  - Each run records the skill versions it used. Skills share a 600-token budget per file.

## Decisions

- **Project:** your hand-made `.xcodeproj` with folders the project picks up automatically, no XcodeGen. App sources are in `MR Command Center/`, tests in `MR Command Center Tests/`, plus a shared scheme.
- **GitLab:** self-managed, 15.7 or later, so the paginated `/diffs` endpoint is used directly.
- **Signing:** you said "sign to run locally," but the project already had team `3BR8562V2D` and this Mac has Apple Development certificates, so I kept it. Signed builds stop the Keychain from asking for access after every rebuild.
- **Pipeline-failed notifications:** only MRs you're reviewing.
- **Bundle ID:** `com.weinnotes.MRCommandCenter`.
- **Swift:** version 6 language mode. Code runs on the main actor by default; network and model types are explicitly `nonisolated`.
- **Inspector:** a `.inspector` panel next to a two-column `NavigationSplitView`. This is the standard macOS way to get a third column you can toggle.
