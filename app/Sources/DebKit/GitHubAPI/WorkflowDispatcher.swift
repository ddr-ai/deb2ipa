import Foundation

/// Injectable sleep, so the 5 s dispatch retry (7.A) and the polling
/// backoff run instantly - and observably - in tests.
public protocol GitHubSleeper: Sendable {
    func sleep(seconds: Double) async
}

public struct TaskGitHubSleeper: GitHubSleeper {
    public init() {}

    public func sleep(seconds: Double) async {
        let clamped = max(0, seconds)
        try? await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
    }
}

/// Sends workflow_dispatch events, retrying once after 5 s on 404/422:
/// a freshly-pushed workflow file may not be synced to the default branch
/// yet (SKILL.md 7.A). Both final 404s and 422s surface as
/// .workflowNotSyncedYet with an actionable message.
public struct GitHubDispatcher: Sendable {
    private let client: GitHubClient
    private let sleeper: GitHubSleeper
    private let retryDelaySeconds: Double

    public init(client: GitHubClient,
                sleeper: GitHubSleeper = TaskGitHubSleeper(),
                retryDelaySeconds: Double = 5) {
        self.client = client
        self.sleeper = sleeper
        self.retryDelaySeconds = retryDelaySeconds
    }

    public func dispatch(workflow: String = "build-ipa.yml",
                         ref: String = "main",
                         inputs: [String: String]) async throws {
        do {
            try await client.dispatch(workflow: workflow, ref: ref, inputs: inputs)
        } catch let error as GitHubAPIError {
            guard Self.isWorkflowSyncIssue(error) else { throw error }
            await sleeper.sleep(seconds: retryDelaySeconds)
            do {
                try await client.dispatch(workflow: workflow, ref: ref, inputs: inputs)
            } catch let retryError as GitHubAPIError {
                if Self.isWorkflowSyncIssue(retryError) {
                    throw GitHubAPIError.workflowNotSyncedYet
                }
                throw retryError
            } catch {
                throw GitHubAPIError.network(String(describing: error))
            }
        } catch {
            throw GitHubAPIError.network(String(describing: error))
        }
    }

    /// The one-tap M6 path: encodes a BuildDispatchRequest and dispatches it.
    public func dispatchBuild(_ request: BuildDispatchRequest,
                              workflow: String = "build-ipa.yml",
                              ref: String = "main") async throws {
        try await dispatch(workflow: workflow, ref: ref, inputs: request.inputs())
    }

    /// 404 = no such workflow on the default branch; 422 = the file exists
    /// but has no workflow_dispatch trigger. Both are the "not synced yet"
    /// family (SKILL.md 7.A).
    static func isWorkflowSyncIssue(_ error: GitHubAPIError) -> Bool {
        switch error {
        case .notFound, .validationFailed:
            return true
        default:
            return false
        }
    }
}
