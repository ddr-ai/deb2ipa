import XCTest
@testable import DebKit

/// M3 acceptance (SKILL.md): dispatch the hello-m3 workflow and observe its
/// completion through the real client, poller, and URLSession transport.
///
/// Runs for real only when DEB2IPA_TOKEN is set (a fine-grained PAT scoped
/// to this repository with Contents and Actions read+write - see
/// docs/PAT-SETUP.md). CI passes the DEB2IPA_TOKEN repo secret through, so
/// once that secret exists this test dispatches a real run on every push;
/// without it the test skips and the mock-transport suite covers the same
/// code paths. The built-in GITHUB_TOKEN cannot be used: events triggered
/// by it never start workflow runs (GitHub recursion prevention).
final class HelloWorkflowLiveTests: XCTestCase {

    func testLiveDispatchHelloWorkflowAndObserveCompletion() async throws {
        guard let token = ProcessInfo.processInfo.environment["DEB2IPA_TOKEN"],
              !token.isEmpty else {
            throw XCTSkip("DEB2IPA_TOKEN not set - live dispatch skipped (add the repo secret, or run on-device with the PAT).")
        }

        let store = InMemoryTokenStore()
        try store.save(token)
        let client = GitHubClient(repository: "ddr-ai/deb2ipa",
                                  transport: URLSessionTransport(),
                                  tokenStore: store)

        _ = try await client.validateToken()

        let dispatcher = GitHubDispatcher(client: client)
        try await dispatcher.dispatch(workflow: "hello-m3.yml", ref: "main", inputs: [:])

        // The dispatch API returns 204 with no run ID, so find the newest
        // run of the workflow (it can take a moment to appear).
        var run: GitHubWorkflowRun?
        for _ in 0..<15 {
            let runs = try await client.listRuns(workflow: "hello-m3.yml", limit: 1)
            if let newest = runs.first {
                run = newest
                break
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        let target = try XCTUnwrap(run, "the dispatched hello-m3 run never appeared")

        let poller = GitHubRunPoller(client: client)
        let final = try await poller.awaitCompletion(runID: target.id)
        XCTAssertTrue(final.succeeded, "hello-m3 finished but not successfully: \(final.conclusion ?? "nil")")
    }
}
