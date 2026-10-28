import XCTest
@testable import DebKit

/// M6 BuildCoordinator: the full convert lifecycle (dispatch → discover →
/// poll) replayed against a scripted transport, including every failure
/// mapping. No network, no real sleeps - the TestSleeper records them.
final class BuildCoordinatorTests: XCTestCase {

    // MARK: - Helpers

    private func response(_ status: Int, _ body: String,
                          headers: [String: String] = [:]) -> GitHubHTTPResponse {
        GitHubHTTPResponse(statusCode: status, headers: headers, body: Data(body.utf8))
    }

    private func ok(_ body: String) -> GitHubHTTPResponse {
        response(200, body)
    }

    private let noContent = GitHubHTTPResponse(statusCode: 204, headers: [:], body: Data())
    private let notFound = GitHubHTTPResponse(statusCode: 404, headers: [:], body: Data())

    /// A runs-list envelope wrapping the given single run JSON.
    private func runsList(containing runJSON: String) -> String {
        "{\"total_count\":1,\"workflow_runs\":[" + runJSON + "]}"
    }

    private let emptyRunsList = "{\"total_count\":0,\"workflow_runs\":[]}"

    private var request: BuildDispatchRequest {
        BuildDispatchRequest(debURL: "https://repo.chariz.com/debs/newterm.deb",
                             packageName: "ws.hbang.newterm3",
                             version: "3.0~beta1",
                             repos: AppPreferences.defaultRepos)
    }

    /// Coordinator wired to a mock transport with injectable sleepers.
    private func makeCoordinator(transport: MockGitHubTransport,
                                 discoveryAttempts: Int = 6,
                                 discoveryDelaySeconds: Double = 5)
        -> (BuildCoordinator, TestSleeper, TestSleeper, TestSleeper) {
        let store = InMemoryTokenStore()
        try? store.save("ghp_test_pat")
        let client = GitHubClient(repository: "ddr-ai/deb2ipa",
                                  transport: transport,
                                  tokenStore: store)
        let dispatcherSleeper = TestSleeper()
        let pollerSleeper = TestSleeper()
        let coordinatorSleeper = TestSleeper()
        let coordinator = BuildCoordinator(
            dispatcher: GitHubDispatcher(client: client, sleeper: dispatcherSleeper),
            client: client,
            poller: GitHubRunPoller(client: client, sleeper: pollerSleeper),
            sleeper: coordinatorSleeper,
            discoveryAttempts: discoveryAttempts,
            discoveryDelaySeconds: discoveryDelaySeconds)
        return (coordinator, dispatcherSleeper, pollerSleeper, coordinatorSleeper)
    }

    // MARK: - Happy path: dispatch, discover the active run, poll to success

    func testConvertFinishesWithSucceededRun() async throws {
        let transport = MockGitHubTransport(queue: [
            .success(noContent),                                   // dispatch 204
            .success(ok(emptyRunsList)),                           // discovery attempt 1: nothing yet
            .success(ok(runsList(containing: GitHubFixtures.runInProgressJSON))),
            .success(ok(GitHubFixtures.runInProgressJSON)),        // poll 1: still building
            .success(ok(GitHubFixtures.runJSON)),                  // poll 2: completed success
        ])
        let (coordinator, dispatcherSleeper, pollerSleeper, coordinatorSleeper) =
            makeCoordinator(transport: transport)

        let result = await coordinator.convert(request)

        guard case .finished(let run) = result else {
            return XCTFail("expected finished, got \(result)")
        }
        XCTAssertEqual(run.id, 40_650_691_548)
        XCTAssertTrue(run.succeeded)
        XCTAssertTrue(result.succeeded)

        // Exactly one dispatch request, on the build workflow.
        let sent = try XCTUnwrap(transport.recordedRequests.first)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.path,
                       "/repos/ddr-ai/deb2ipa/actions/workflows/build-ipa.yml/dispatches")

        // Discovery waited once between the two attempts; the dispatch
        // retry never fired; the poller backed off once (2 s).
        XCTAssertEqual(coordinatorSleeper.recorded, [5])
        XCTAssertEqual(dispatcherSleeper.recorded, [])
        XCTAssertEqual(pollerSleeper.recorded, [2])
    }

    func testConvertFinishesWithFailedRun() async throws {
        // The run completes with conclusion "failure": the M5 workflow
        // leaves a diagnostic draft - still a finished state, not an error.
        let transport = MockGitHubTransport(queue: [
            .success(noContent),
            .success(ok(runsList(containing: GitHubFixtures.runInProgressJSON))),
            .success(ok(GitHubFixtures.runFailedJSON)),
        ])
        let (coordinator, _, _, _) = makeCoordinator(transport: transport)

        let result = await coordinator.convert(request)

        guard case .finished(let run) = result else {
            return XCTFail("expected finished, got \(result)")
        }
        XCTAssertEqual(run.conclusion, "failure")
        XCTAssertFalse(run.succeeded)
        XCTAssertFalse(result.succeeded)
    }

    func testConvertUsesCompletedRunAsFallback() async throws {
        // A very fast build may already be completed when discovery looks:
        // the newest run is then used as the fallback. All 6 discovery
        // attempts re-list (no active run breaks the loop early).
        let transport = MockGitHubTransport(queue: [
            .success(noContent),
        ] + Array(repeating: .success(ok(GitHubFixtures.runsListJSON)), count: 6)
          + [.success(ok(GitHubFixtures.runJSON))])   // poll: completed
        let (coordinator, _, _, coordinatorSleeper) =
            makeCoordinator(transport: transport)

        let result = await coordinator.convert(request)

        guard case .finished(let run) = result else {
            return XCTFail("expected finished, got \(result)")
        }
        XCTAssertEqual(run.id, 40_650_691_548)
        XCTAssertTrue(run.succeeded)
        // Sleeps between the six attempts, none after the last.
        XCTAssertEqual(coordinatorSleeper.recorded.count, 5)
    }

    // MARK: - Failure paths (typed, explained states)

    func testConvertFailsWhenDispatchStaysNotFound() async throws {
        // 404, 404: the dispatcher retries once (5 s), then surfaces
        // workflowNotSyncedYet as a user-facing message.
        let transport = MockGitHubTransport(queue: [
            .success(notFound),
            .success(notFound),
        ])
        let (coordinator, dispatcherSleeper, _, coordinatorSleeper) =
            makeCoordinator(transport: transport)

        let result = await coordinator.convert(request)

        guard case .failed(let message) = result else {
            return XCTFail("expected failed, got \(result)")
        }
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(message.contains("not on the default branch"), message)
        XCTAssertEqual(dispatcherSleeper.recorded, [5])
        XCTAssertEqual(coordinatorSleeper.recorded, [])
    }

    func testConvertFailsWhenNoTokenIsSaved() async throws {
        // No PAT in the store: the failure surfaces before any request.
        let store = InMemoryTokenStore()   // deliberately empty
        let transport = MockGitHubTransport(queue: [])
        let client = GitHubClient(repository: "ddr-ai/deb2ipa",
                                  transport: transport,
                                  tokenStore: store)
        let coordinator = BuildCoordinator(
            dispatcher: GitHubDispatcher(client: client, sleeper: TestSleeper()),
            client: client,
            poller: GitHubRunPoller(client: client, sleeper: TestSleeper()))

        let result = await coordinator.convert(request)

        guard case .failed(let message) = result else {
            return XCTFail("expected failed, got \(result)")
        }
        XCTAssertTrue(message.contains("No GitHub token is saved"), message)
        XCTAssertTrue(message.contains("Settings"), message)
        XCTAssertTrue(transport.recordedRequests.isEmpty)
    }

    func testConvertFailsWhenRunNeverAppears() async throws {
        // Discovery exhausts its attempts with an empty runs list: the
        // run was dispatched but never became visible.
        let transport = MockGitHubTransport(queue: [
            .success(noContent),
            .success(ok(emptyRunsList)),
            .success(ok(emptyRunsList)),
            .success(ok(emptyRunsList)),
        ])
        let (coordinator, _, _, coordinatorSleeper) =
            makeCoordinator(transport: transport,
                            discoveryAttempts: 3,
                            discoveryDelaySeconds: 1)

        let result = await coordinator.convert(request)

        guard case .failed(let message) = result else {
            return XCTFail("expected failed, got \(result)")
        }
        XCTAssertTrue(message.contains("did not appear"), message)
        XCTAssertTrue(message.contains("Actions tab"), message)
        // Sleeps between the three attempts, none after the last.
        XCTAssertEqual(coordinatorSleeper.recorded, [1, 1])
        XCTAssertEqual(transport.recordedRequests.count, 4)
    }

    func testConvertFailsWhenDiscoveryListingErrors() async throws {
        // A transport error during discovery (here: rate limited) is
        // mapped to its user message instead of crashing.
        let rateLimited = GitHubHTTPResponse(
            statusCode: 403,
            headers: ["x-ratelimit-remaining": "0",
                      "x-ratelimit-reset": "1790000000"],
            body: Data("{\"message\":\"API rate limit exceeded\"}".utf8))
        let transport = MockGitHubTransport(queue: [
            .success(noContent),
            .success(.failure(rateLimited)),
        ])
        let (coordinator, _, _, coordinatorSleeper) =
            makeCoordinator(transport: transport)

        let result = await coordinator.convert(request)

        guard case .failed(let message) = result else {
            return XCTFail("expected failed, got \(result)")
        }
        XCTAssertTrue(message.contains("rate limit"), message)
        XCTAssertEqual(coordinatorSleeper.recorded, [])
    }

    func testConvertPropagatesPollerErrors() async throws {
        // The poller gives up after maxPolls: the timeout error carries a
        // user-facing message through the coordinator.
        let transport = MockGitHubTransport(queue: [
            .success(noContent),
            .success(ok(runsList(containing: GitHubFixtures.runQueuedJSON))),
        ] + Array(repeating: .success(ok(GitHubFixtures.runQueuedJSON)), count: 4))
        let store = InMemoryTokenStore()
        try? store.save("ghp_test_pat")
        let client = GitHubClient(repository: "ddr-ai/deb2ipa",
                                  transport: transport,
                                  tokenStore: store)
        let coordinator = BuildCoordinator(
            dispatcher: GitHubDispatcher(client: client, sleeper: TestSleeper()),
            client: client,
            poller: GitHubRunPoller(client: client,
                                    sleeper: TestSleeper(),
                                    maxPolls: 4))

        let result = await coordinator.convert(request)

        guard case .failed(let message) = result else {
            return XCTFail("expected failed, got \(result)")
        }
        XCTAssertTrue(message.contains("did not finish"), message)
    }
}
