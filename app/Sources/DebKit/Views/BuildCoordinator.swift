import Foundation

/// Orchestrates one full conversion: dispatch the workflow, discover the
/// run it created, poll it to completion. Built on the M3 stack
/// (GitHubDispatcher / GitHubClient / GitHubRunPoller) with injectable
/// sleeps, so the whole lifecycle is replayable in mock-transport tests
/// on the Linux CI.
public struct BuildCoordinator: Sendable {

    /// Terminal state of one conversion attempt. Every failure is a typed,
    /// explained state - the Build screen never renders a raw error.
    public enum Result: Equatable, Sendable {
        /// The run completed. `run.succeeded` says whether the IPA was
        /// published; the workflow's launchability gate leaves failures as
        /// drafts with a red run (SKILL.md M5).
        case finished(GitHubWorkflowRun)
        /// The conversion could not start or complete; `message` is
        /// user-facing (built from GitHubAPIError.userMessage).
        case failed(String)

        public var succeeded: Bool {
            if case .finished(let run) = self { return run.succeeded }
            return false
        }
    }

    private let dispatcher: GitHubDispatcher
    private let client: GitHubClient
    private let poller: GitHubRunPoller
    private let sleeper: GitHubSleeper

    /// How many listRuns attempts we make to find our run after dispatch,
    /// and how long to wait between them. A freshly dispatched run is not
    /// immediately visible in the API (M3 lesson 7.A) - the discovery
    /// window absorbs that.
    private let discoveryAttempts: Int
    private let discoveryDelaySeconds: Double

    public init(dispatcher: GitHubDispatcher,
                client: GitHubClient,
                poller: GitHubRunPoller,
                sleeper: GitHubSleeper = TaskGitHubSleeper(),
                discoveryAttempts: Int = 6,
                discoveryDelaySeconds: Double = 5) {
        self.dispatcher = dispatcher
        self.client = client
        self.poller = poller
        self.sleeper = sleeper
        self.discoveryAttempts = max(1, discoveryAttempts)
        self.discoveryDelaySeconds = discoveryDelaySeconds
    }

    /// Runs one conversion end to end and returns the terminal state.
    public func convert(_ request: BuildDispatchRequest,
                        workflow: String = AppPreferences.defaultWorkflowFile) async -> Result {
        // 1. Dispatch. The dispatcher already retries once on the
        //    not-synced-yet family (404/422).
        do {
            try await dispatcher.dispatchBuild(request, workflow: workflow)
        } catch {
            return .failed(Self.userMessage(for: error))
        }

        // 2. Discover our run: prefer an active run (ours just started);
        //    keep the newest run as a fallback for very fast completions.
        var discovered: GitHubWorkflowRun?
        var fallback: GitHubWorkflowRun?
        for attempt in 0..<discoveryAttempts {
            do {
                let runs = try await client.listRuns(workflow: workflow, limit: 5)
                if let active = runs.first(where: { !$0.isCompleted }) {
                    discovered = active
                    break
                }
                if fallback == nil { fallback = runs.first }
            } catch {
                return .failed(Self.userMessage(for: error))
            }
            if attempt + 1 < discoveryAttempts {
                await sleeper.sleep(seconds: discoveryDelaySeconds)
            }
        }
        guard let run = discovered ?? fallback else {
            return .failed("The conversion was dispatched, but its workflow run "
                           + "did not appear within \(Int(Double(discoveryAttempts) * discoveryDelaySeconds)) seconds. "
                           + "Check the Actions tab of the repository.")
        }

        // 3. Poll to completion. The poller tolerates the brief
        //    run-visibility 404s right after dispatch (M3).
        do {
            let final = try await poller.awaitCompletion(runID: run.id)
            return .finished(final)
        } catch {
            return .failed(Self.userMessage(for: error))
        }
    }

    /// User-facing message for any thrown error: GitHub errors carry their
    /// own `userMessage`; anything else is described generically rather
    /// than crashing.
    private static func userMessage(for error: Error) -> String {
        if let apiError = error as? GitHubAPIError {
            return apiError.userMessage
        }
        if let tokenError = error as? TokenStoreError {
            return "The saved GitHub token could not be read: \(tokenError.message)"
        }
        return "The conversion failed: \(error.localizedDescription)"
    }
}
