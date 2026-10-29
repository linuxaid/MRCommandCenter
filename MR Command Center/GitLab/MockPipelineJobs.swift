import Foundation

/// Failed jobs and their logs for the mock data's failed pipelines (#35). The logs carry the
/// colour codes and section markers a real GitLab runner writes.
nonisolated enum MockPipelineJobs {
    static func failedJobs(pipelineID: Int, pipelineURL: String?) -> [GitLabJob] {
        let base = pipelineURL?.components(separatedBy: "/-/pipelines").first ?? "https://gitlab.example.com"
        return [
            GitLabJob(id: pipelineID * 10 + 1, name: "lint:style", stage: "test", status: "failed",
                      failureReason: "script_failure", webUrl: "\(base)/-/jobs/\(pipelineID * 10 + 1)", allowFailure: true),
            GitLabJob(id: pipelineID * 10 + 2, name: "test:unit", stage: "test", status: "failed",
                      failureReason: "script_failure", webUrl: "\(base)/-/jobs/\(pipelineID * 10 + 2)", allowFailure: false),
        ]
    }

    static func log(jobID: Int) -> String {
        let esc = "\u{1B}"
        if jobID % 10 == 1 {
            return """
            \(esc)[0KRunning with gitlab-runner 17.4.0\r
            section_start:1730000000:step_script\r\(esc)[0K\(esc)[0K\(esc)[36;1mExecuting "step_script" stage of the job script\(esc)[0;m\r
            \(esc)[32;1m$ npm run lint\(esc)[0;m\r
            src/cart/CartView.tsx\r
              14:7  warning  'unused' is assigned a value but never used  no-unused-vars\r
            \r
            ✖ 1 problem (0 errors, 1 warning)\r
            section_end:1730000004:step_script\r\(esc)[0K\(esc)[31;1mERROR: Job failed: exit code 1\(esc)[0;m\r

            """
        }
        var lines = [
            "\(esc)[0KRunning with gitlab-runner 17.4.0",
            "section_start:1730000000:prepare_executor\r\(esc)[0K\(esc)[0K\(esc)[36;1mPreparing the \"docker\" executor\(esc)[0;m",
            "Using Docker executor with image node:22 ...",
            "section_end:1730000003:prepare_executor\r\(esc)[0K",
            "section_start:1730000003:step_script[collapsed=true]\r\(esc)[0K\(esc)[0K\(esc)[36;1mExecuting \"step_script\" stage of the job script\(esc)[0;m",
            "\(esc)[32;1m$ npm ci\(esc)[0;m",
            "Installing 1/3\rInstalling 2/3\rInstalling 3/3\radded 812 packages in 14s",
            "\(esc)[32;1m$ npm test -- --ci\(esc)[0;m",
        ]
        lines += (1...40).map { " PASS  src/module\($0).test.ts" }
        lines += [
            " \(esc)[31mFAIL\(esc)[39m  src/webhooks/retry.test.ts",
            "  ● retries › gives up after five attempts",
            "",
            "    expect(received).toBe(expected) // Object.is equality",
            "",
            "    Expected: 5",
            "    Received: 6",
            "",
            "      42 |     await flushRetries()",
            "    > 43 |     expect(attempts).toBe(5)",
            "         |                      ^",
            "",
            "Tests:       1 failed, 41 passed, 42 total",
            "section_end:1730000060:step_script\r\(esc)[0K\(esc)[31;1mERROR: Job failed: exit code 1\(esc)[0;m",
            "",
        ]
        return lines.joined(separator: "\r\n")
    }
}
