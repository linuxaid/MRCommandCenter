import Foundation
import Synchronization
import Testing
@testable import MR_Command_Center

/// Job logs made readable (#35).
struct JobLogTests {
    private let esc = "\u{1B}"

    @Test func colourCodesAreRemoved() {
        #expect(JobLog.lines("\(esc)[32;1m$ npm test\(esc)[0;m") == ["$ npm test"])
        #expect(JobLog.lines("\(esc)[0K\(esc)[31mFAIL\(esc)[39m a.test.ts") == ["FAIL a.test.ts"])
    }

    @Test func sectionMarkersAreRemoved() {
        let raw = "section_start:1730000003:step_script[collapsed=true]\r\(esc)[0K\(esc)[36;1mExecuting\(esc)[0;m\nsection_end:1730000060:step_script\r\(esc)[0KERROR: Job failed"
        #expect(JobLog.lines(raw) == ["Executing", "ERROR: Job failed"])
    }

    @Test func aRedrawnLineKeepsItsLastDrawing() {
        #expect(JobLog.lines("Installing 1/3\rInstalling 2/3\rdone") == ["done"])
    }

    @Test func windowsLineEndsSplit() {
        // `\r\n` is a single Character, so this would be one line if split on "\n".
        #expect(JobLog.lines("one\r\ntwo\r\nthree") == ["one", "two", "three"])
        #expect(JobLog.lines("one\r\r\ntwo") == ["one", "two"])
    }

    @Test func sectionOnlyLinesAreDropped() {
        #expect(JobLog.lines("a\nsection_end:1730000003:prepare_executor\r\(esc)[0K\nb") == ["a", "b"])
    }

    @Test func otherEscapesAreRemovedWhole() {
        #expect(JobLog.lines("\(esc)]8;;https://x.test\u{07}link\(esc)]8;;\u{07} done") == ["link done"])
        #expect(JobLog.lines("\(esc)(Bplain\(esc)[?25h") == ["plain"])
    }

    @Test func aHugeLogKeepsTheSameTail() {
        let raw = (1...100_000).map { "\(esc)[32mline \($0)\(esc)[0m" }.joined(separator: "\n") + "\n\n"
        let tail = JobLog.tail(raw)
        #expect(tail.lines.count == JobLog.tailLength)
        #expect(tail.lines.last == "line 100000")
        #expect(tail.omitted == 100_000 - JobLog.tailLength)
    }

    @Test func blankLinesInsideStayAndTrailingOnesGo() {
        #expect(JobLog.lines("a\n\nb\n\n\n") == ["a", "", "b"])
        #expect(JobLog.lines("") == [])
    }

    @Test func tailKeepsTheEndAndCountsTheRest() {
        let raw = (1...250).map { "line \($0)" }.joined(separator: "\n")
        let tail = JobLog.tail(raw, length: 200)
        #expect(tail.lines.count == 200)
        #expect(tail.lines.first == "line 51")
        #expect(tail.lines.last == "line 250")
        #expect(tail.omitted == 50)
        #expect(JobLog.tail("a\nb", length: 200).omitted == 0)
    }

    @Test func theMockLogReadsCleanly() {
        let lines = JobLog.lines(MockPipelineJobs.log(jobID: 1732))
        #expect(lines.contains("added 812 packages in 14s"))
        #expect(lines.last == "ERROR: Job failed: exit code 1")
        #expect(!lines.contains { $0.contains("\u{1B}") || $0.contains("\r") || $0.contains("section_") })
    }
}

struct GitLabJobTests {
    @Test func failureReasonsReadAsWords() {
        func job(_ reason: String?) -> GitLabJob {
            GitLabJob(id: 1, name: "test", stage: "test", status: "failed", failureReason: reason)
        }
        #expect(job("script_failure").failureText == "The job's script failed")
        #expect(job("job_execution_timeout").failureText == "Timed out")
        #expect(job("some_new_reason").failureText == "Some new reason")
        #expect(job(nil).failureText == nil)
        #expect(job("").failureText == nil)
    }

    @Test func decodesGitLabsJobList() throws {
        let json = #"[{"id":7,"name":"test:unit","stage":"test","status":"failed","failure_reason":"script_failure","web_url":"https://g/-/jobs/7","allow_failure":false,"extra":1}]"#
        let jobs = try JSONDecoder.gitLab.decode([GitLabJob].self, from: Data(json.utf8))
        #expect(jobs == [GitLabJob(id: 7, name: "test:unit", stage: "test", status: "failed", failureReason: "script_failure",
                                   webUrl: "https://g/-/jobs/7", allowFailure: false)])
    }
}

/// The brief's "Why the pipeline failed" card (#35).
@MainActor
struct PipelineFailuresTests {
    private func loaded() async -> (AppModel, SpyGitLabClient) {
        let spy = SpyGitLabClient()
        let app = AppModel.testing(gitLab: spy)
        await app.refresh(.automatic)
        return (app, spy)
    }

    private func mr(_ app: AppModel, _ iid: Int) throws -> TrackedMR {
        try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == iid })
    }

    @Test func shownOnlyForAFailedPipeline() async throws {
        let (app, _) = await loaded()
        #expect(PipelineFailures.isShown(for: try mr(app, 1873)))
        #expect(!PipelineFailures.isShown(for: try mr(app, 412)), "Passed")
        #expect(!PipelineFailures.isShown(for: try mr(app, 77)), "Running")
        #expect(!PipelineFailures.isShown(for: try mr(app, 1884)), "No pipeline")
    }

    @Test func listsTheJobsThatBrokeThePipelineFirst() async throws {
        let (app, spy) = await loaded()
        let failed = try mr(app, 1873)
        let failures = PipelineFailures()

        await failures.load(projectID: failed.projectID, pipelineID: try #require(failed.pipelineID), client: { spy })

        guard case .loaded(let jobs) = failures.phase else { Issue.record("Not loaded: \(failures.phase)"); return }
        #expect(jobs.map(\.name) == ["test:unit", "lint:style"])
        let breaking = try #require(PipelineFailures.jobToOpen(jobs))
        #expect(breaking.name == "test:unit")
        #expect(failures.openJobs == [breaking.id], "The only breaking job opens by itself")
        #expect(spy.count("jobLog") == 1)
        guard case .loaded? = failures.logs[breaking.id] else { Issue.record("Its log isn't loaded"); return }
    }

    @Test func togglingAJobShowsAndHidesItsLog() async throws {
        let (app, spy) = await loaded()
        let failed = try mr(app, 1873)
        let failures = PipelineFailures()
        await failures.load(projectID: failed.projectID, pipelineID: try #require(failed.pipelineID), client: { spy })
        guard case .loaded(let jobs) = failures.phase else { Issue.record("Not loaded"); return }
        let allowed = try #require(jobs.last)

        await failures.toggle(allowed, projectID: failed.projectID, client: { spy })
        #expect(failures.openJobs.contains(allowed.id))
        await failures.toggle(allowed, projectID: failed.projectID, client: { spy })
        #expect(!failures.openJobs.contains(allowed.id))
        await failures.toggle(allowed, projectID: failed.projectID, client: { spy })
        #expect(spy.count("jobLog") == 2, "The auto-opened job's log and this one's, each once")
    }

    @Test func aClientThatCantBeMadeIsExplained() async throws {
        let failures = PipelineFailures()
        await failures.load(projectID: 1, pipelineID: 2, client: { throw APIError.missingToken })
        guard case .failed = failures.phase else { Issue.record("Still \(failures.phase)"); return }
        await failures.loadLog(of: GitLabJob(id: 3, name: "t", status: "failed"), projectID: 1,
                               client: { throw APIError.missingToken })
        guard case .failed? = failures.logs[3] else { Issue.record("Log not failed"); return }
    }

    @Test func tryingTheJobListAgainLoadsIt() async throws {
        let (app, spy) = await loaded()
        let failed = try mr(app, 1873)
        let pipelineID = try #require(failed.pipelineID)
        let failures = PipelineFailures()
        spy.edit { $0.jobsFailure = .forbidden }
        await failures.load(projectID: failed.projectID, pipelineID: pipelineID, client: { spy })
        guard case .failed = failures.phase else { Issue.record("Not failed"); return }

        spy.edit { $0.jobsFailure = nil }
        await failures.load(projectID: failed.projectID, pipelineID: pipelineID, client: { spy })

        guard case .loaded = failures.phase else { Issue.record("Not loaded: \(failures.phase)"); return }
    }

    @Test func aLateLogForAnOldPipelineIsDropped() async throws {
        let (app, spy) = await loaded()
        let failed = try mr(app, 1873)
        let other = try mr(app, 80)
        let failures = PipelineFailures()
        spy.edit { $0.jobsFailure = .forbidden }  // No auto-open, so only the log below is in flight.
        await failures.load(projectID: failed.projectID, pipelineID: try #require(failed.pipelineID), client: { spy })
        spy.edit {
            $0.jobsFailure = nil
            $0.jobLogDelay = .milliseconds(300)
        }
        let late = Task {
            await failures.loadLog(of: GitLabJob(id: 99, name: "t", status: "failed"), projectID: failed.projectID,
                                   client: { spy })
        }
        try await Task.sleep(for: .milliseconds(50))

        await failures.load(projectID: other.projectID, pipelineID: try #require(other.pipelineID), client: { spy })
        await late.value

        #expect(failures.pipelineID == other.pipelineID)
        #expect(failures.logs[99] == nil, "The old pipeline's log arrived late and was dropped")
    }

    @Test func opensNothingByItselfWhenSeveralJobsBrokeIt() {
        let jobs = [GitLabJob(id: 1, name: "a", status: "failed"), GitLabJob(id: 2, name: "b", status: "failed")]
        #expect(PipelineFailures.jobToOpen(jobs) == nil)
        #expect(PipelineFailures.jobToOpen([GitLabJob(id: 3, name: "c", status: "failed", allowFailure: true)]) == nil)
    }

    @Test func loadsALogOnceAndKeepsItsEnd() async throws {
        let (app, spy) = await loaded()
        let failed = try mr(app, 1873)
        spy.edit { $0.jobLogOverride = (1...500).map { "line \($0)" }.joined(separator: "\n") }
        let failures = PipelineFailures()
        let pipelineID = try #require(failed.pipelineID)
        await failures.load(projectID: failed.projectID, pipelineID: pipelineID, client: { spy })
        let job = GitLabJob(id: 99, name: "test", status: "failed")

        await failures.loadLog(of: job, projectID: failed.projectID, client: { spy })
        await failures.loadLog(of: job, projectID: failed.projectID, client: { spy })

        #expect(spy.count("jobLog") == 2, "The auto-opened job's log, and this one's once")
        guard case .loaded(let lines, let omitted)? = failures.logs[99] else { Issue.record("No log"); return }
        #expect(lines.count == JobLog.tailLength)
        #expect(lines.last == "line 500")
        #expect(omitted == 500 - JobLog.tailLength)
    }

    @Test func aFailedLogCanBeTriedAgain() async throws {
        let (app, spy) = await loaded()
        let failed = try mr(app, 1873)
        let failures = PipelineFailures()
        await failures.load(projectID: failed.projectID, pipelineID: try #require(failed.pipelineID), client: { spy })
        let job = GitLabJob(id: 99, name: "test", status: "failed")
        spy.edit { $0.jobLogFailure = .notFound }

        await failures.loadLog(of: job, projectID: failed.projectID, client: { spy })
        guard case .failed(let message)? = failures.logs[99] else { Issue.record("Not failed"); return }
        #expect(message.contains("404"))

        spy.edit { $0.jobLogFailure = nil }
        await failures.loadLog(of: job, projectID: failed.projectID, client: { spy })
        guard case .loaded? = failures.logs[99] else { Issue.record("Not retried"); return }
    }

    @Test func jobListFailureIsExplained() async throws {
        let (app, spy) = await loaded()
        let failed = try mr(app, 1873)
        spy.edit { $0.jobsFailure = .forbidden }
        let failures = PipelineFailures()

        await failures.load(projectID: failed.projectID, pipelineID: try #require(failed.pipelineID), client: { spy })

        guard case .failed(let message) = failures.phase else { Issue.record("Not failed"); return }
        #expect(message.contains("403"))
    }

    @Test func aNewPipelineStartsOver() async throws {
        let (app, spy) = await loaded()
        let failed = try mr(app, 1873)
        let failures = PipelineFailures()
        let pipelineID = try #require(failed.pipelineID)
        await failures.load(projectID: failed.projectID, pipelineID: pipelineID, client: { spy })
        await failures.loadLog(of: GitLabJob(id: 99, name: "t", status: "failed"), projectID: failed.projectID, client: { spy })
        #expect(failures.logs[99] != nil)

        let other = try mr(app, 80)
        await failures.load(projectID: other.projectID, pipelineID: try #require(other.pipelineID), client: { spy })

        #expect(failures.logs.isEmpty, "Old logs are dropped")
        #expect(failures.openJobs.isEmpty)
        #expect(failures.phase == .loaded([]), "A canceled pipeline lists no failed jobs in the mock")
    }

    @Test func liveClientAsksForFailedJobsAndTheTrace() async throws {
        let transport = StubTransport([.response(status: 200, body: Data("[]".utf8)),
                                       .response(status: 200, body: Data("log text".utf8))])
        let client = LiveGitLabClient(baseURL: URL(string: "https://gitlab.example.com")!, token: "t", transport: transport)

        _ = try await client.failedJobs(projectID: 101, pipelineID: 5)
        let log = try await client.jobLog(projectID: 101, jobID: 7)

        let sent = transport.requests
        #expect(sent[0].url?.path() == "/api/v4/projects/101/pipelines/5/jobs")
        let query = try #require(sent[0].url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems)
        #expect(query.contains(URLQueryItem(name: "scope[]", value: "failed")))
        #expect(sent[1].url?.path() == "/api/v4/projects/101/jobs/7/trace")
        #expect(log == "log text")
    }
}
