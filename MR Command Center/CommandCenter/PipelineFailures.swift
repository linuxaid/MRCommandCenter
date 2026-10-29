import Foundation
import Observation

/// Why an MR's pipeline failed (#35): its failed jobs, and each one's log on request.
@Observable
final class PipelineFailures {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded([GitLabJob])
        case failed(String)
    }

    enum Log: Equatable {
        case loading
        case loaded(lines: [String], omitted: Int)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Logs by job ID, fetched when a job is opened.
    private(set) var logs: [Int: Log] = [:]
    /// The pipeline the jobs belong to, so a newer pipeline starts over.
    private(set) var pipelineID: Int?

    /// The brief explains a failed pipeline, once GitLab has said which one it is.
    static func isShown(for mr: TrackedMR) -> Bool {
        mr.pipelineStatus == .failed && mr.pipelineID != nil
    }

    /// Jobs that broke the pipeline first, then ones allowed to fail; each group in GitLab's order.
    nonisolated static func ordered(_ jobs: [GitLabJob]) -> [GitLabJob] {
        jobs.filter { $0.allowFailure != true } + jobs.filter { $0.allowFailure == true }
    }

    /// The job worth opening straight away: the only one that broke the pipeline.
    nonisolated static func jobToOpen(_ jobs: [GitLabJob]) -> GitLabJob? {
        let breaking = jobs.filter { $0.allowFailure != true }
        return breaking.count == 1 ? breaking[0] : nil
    }

    func load(projectID: Int, pipelineID: Int, client: any GitLabAPI) async {
        if self.pipelineID != pipelineID {
            self.pipelineID = pipelineID
            logs = [:]
            phase = .loading
        }
        do {
            let jobs = try await client.failedJobs(projectID: projectID, pipelineID: pipelineID)
            guard self.pipelineID == pipelineID else { return }
            phase = .loaded(Self.ordered(jobs))
        } catch is CancellationError {
            return
        } catch {
            guard self.pipelineID == pipelineID else { return }
            phase = .failed(Self.describe(error))
        }
    }

    /// Fetches a job's log once; a failed fetch can be tried again.
    func loadLog(of job: GitLabJob, projectID: Int, client: any GitLabAPI) async {
        if case .loaded = logs[job.id] { return }
        if logs[job.id] == .loading { return }
        let pipelineID = pipelineID
        logs[job.id] = .loading
        do {
            let raw = try await client.jobLog(projectID: projectID, jobID: job.id)
            guard self.pipelineID == pipelineID else { return }
            let tail = await Self.tail(raw)
            guard self.pipelineID == pipelineID else { return }
            logs[job.id] = .loaded(lines: tail.lines, omitted: tail.omitted)
        } catch {
            guard self.pipelineID == pipelineID else { return }
            logs[job.id] = .failed(Self.describe(error))
        }
    }

    /// Logs can run to megabytes, so they're cleaned off the main actor.
    @concurrent
    private static func tail(_ raw: String) async -> (lines: [String], omitted: Int) {
        JobLog.tail(raw)
    }

    nonisolated static func describe(_ error: any Error) -> String {
        switch error as? APIError {
        case .forbidden?:
            "GitLab refused (403). Reading job logs needs Reporter access to the project."
        case .notFound?:
            "GitLab couldn't find it (404). The job may have been erased."
        default:
            error.localizedDescription
        }
    }
}
