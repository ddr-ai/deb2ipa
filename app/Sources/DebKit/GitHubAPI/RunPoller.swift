import Foundation

/// Polls a workflow run to completion with exponential backoff (2 s doubling,
/// capped at 30 s - SKILL.md 7.J). The client's ETag cache makes each poll
/// cheap: GitHub does not count 304 responses against the rate limit.
public struct GitHubRunPoller: Sendable {
    private let client: GitHubClient
    private let sleeper: GitHubSleeper
    private let initialDelaySeconds: Double
    private let maxDelaySeconds: Double
    private let maxPolls: Int

    public init(client: GitHubClient,
                sleeper: GitHubSleeper = TaskGitHubSleeper(),
                initialDelaySeconds: Double = 2,
                maxDelaySeconds: Double = 30,
                maxPolls: Int = 120) {
        self.client = client
        self.sleeper = sleeper
        self.initialDelaySeconds = initialDelaySeconds
        self.maxDelaySeconds = maxDelaySeconds
        self.maxPolls = maxPolls
    }

    /// Polls immediately, then with backoff until the run completes.
    /// With the default budget this survives roughly an hour of building.
    public func awaitCompletion(runID: Int64) async throws -> GitHubWorkflowRun {
        var delay = initialDelaySeconds
        for pollIndex in 0..<maxPolls {
            let run = try await pollOnce(runID: runID)
            if run.isCompleted {
                return run
            }
            if pollIndex + 1 < maxPolls {
                await sleeper.sleep(seconds: delay)
                delay = min(delay * 2, maxDelaySeconds)
            }
        }
        throw GitHubAPIError.pollingTimeout(maxPolls: maxPolls)
    }

    /// A run can 404 briefly right after dispatch, before it becomes
    /// visible; treat that as "still queued" instead of failing.
    private func pollOnce(runID: Int64) async throws -> GitHubWorkflowRun {
        do {
            return try await client.run(runID)
        } catch let error as GitHubAPIError {
            if case .notFound = error {
                return GitHubWorkflowRun(id: runID, name: nil, status: "queued",
                                         conclusion: nil, htmlURL: nil, createdAt: nil,
                                         updatedAt: nil, headSHA: nil)
            }
            throw error
        }
    }
}
