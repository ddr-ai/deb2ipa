import XCTest
@testable import DebKit

final class GitHubClientTests: XCTestCase {

    // MARK: - Helpers

    private func response(_ status: Int, _ body: String,
                          headers: [String: String] = [:]) -> GitHubHTTPResponse {
        GitHubHTTPResponse(statusCode: status, headers: headers, body: Data(body.utf8))
    }

    private func ok(_ body: String, etag: String? = nil) -> GitHubHTTPResponse {
        var headers: [String: String] = [:]
        if let etag { headers["etag"] = etag }
        return response(200, body, headers: headers)
    }

    private let noContent = GitHubHTTPResponse(statusCode: 204, headers: [:], body: Data())

    private func makeClient(_ transport: MockGitHubTransport,
                            token: String = "ghp_test_pat") -> GitHubClient {
        let store = InMemoryTokenStore()
        try? store.save(token)
        return GitHubClient(repository: "ddr-ai/deb2ipa", transport: transport, tokenStore: store)
    }

    private func makeDispatcher(_ client: GitHubClient, sleeper: TestSleeper) -> GitHubDispatcher {
        GitHubDispatcher(client: client, sleeper: sleeper)
    }

    // MARK: - Dispatch (SKILL.md 7.A)

    func testDispatchSendsTheContractedRequest() async throws {
        let transport = MockGitHubTransport(queue: [.success(noContent)])
        let request = BuildDispatchRequest(
            debURL: "https://example.org/app.deb",
            packageName: "com.example.app",
            version: "1.0",
            bundleID: "com.example.app",
            displayName: "Example",
            repos: ["https://repo.chariz.com/"])
        try await makeDispatcher(makeClient(transport), sleeper: TestSleeper())
            .dispatchBuild(request)

        XCTAssertEqual(transport.recordedRequests.count, 1)
        let sent = try XCTUnwrap(transport.recordedRequests.first)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.path, "/repos/ddr-ai/deb2ipa/actions/workflows/build-ipa.yml/dispatches")
        XCTAssertEqual(sent.headers["Authorization"], "Bearer ghp_test_pat")
        XCTAssertEqual(sent.headers["Accept"], "application/vnd.github+json")
        XCTAssertEqual(sent.headers["X-GitHub-Api-Version"], "2022-11-28")
        XCTAssertEqual(sent.headers["Content-Type"], "application/json")
        let body = try XCTUnwrap(String(data: sent.body ?? Data(), encoding: .utf8))
        XCTAssertTrue(body.contains("\"ref\":\"main\""))
        XCTAssertTrue(body.contains("\"deb_url\":\"https://example.org/app.deb\""))
        XCTAssertTrue(body.contains("\"package_name\":\"com.example.app\""))
        XCTAssertTrue(body.contains("repo.chariz.com"))
    }

    func testDispatchRetriesOnceAfter5SecondsOn404() async throws {
        let sleeper = TestSleeper()
        let transport = MockGitHubTransport(queue: [
            .success(response(404, "{\"message\":\"Not Found\"}")),
            .success(noContent),
        ])
        try await makeDispatcher(makeClient(transport), sleeper: sleeper)
            .dispatch(workflow: "build-ipa.yml", inputs: [:])
        XCTAssertEqual(transport.recordedRequests.count, 2)
        XCTAssertEqual(sleeper.recorded, [5])
    }

    func testDispatchRetriesOnceAfter5SecondsOn422() async throws {
        let sleeper = TestSleeper()
        let transport = MockGitHubTransport(queue: [
            .success(response(422, "{\"message\":\"Workflow does not have 'workflow_dispatch' trigger\"}")),
            .success(noContent),
        ])
        try await makeDispatcher(makeClient(transport), sleeper: sleeper)
            .dispatch(workflow: "build-ipa.yml", inputs: [:])
        XCTAssertEqual(transport.recordedRequests.count, 2)
        XCTAssertEqual(sleeper.recorded, [5])
    }

    func testDispatchDoesNotRetryOn401() async throws {
        let sleeper = TestSleeper()
        let transport = MockGitHubTransport(queue: [
            .success(response(401, "{\"message\":\"Bad credentials\"}")),
        ])
        do {
            try await makeDispatcher(makeClient(transport), sleeper: sleeper)
                .dispatch(workflow: "build-ipa.yml", inputs: [:])
            XCTFail("expected unauthorized")
        } catch let error as GitHubAPIError {
            XCTAssertEqual(error, .unauthorized)
        }
        XCTAssertEqual(transport.recordedRequests.count, 1)
        XCTAssertTrue(sleeper.recorded.isEmpty)
    }

    func testDispatchSurfacesWorkflowNotSyncedYetAfterRetry() async throws {
        let sleeper = TestSleeper()
        let transport = MockGitHubTransport(queue: [
            .success(response(404, "{\"message\":\"Not Found\"}")),
            .success(response(404, "{\"message\":\"Not Found\"}")),
        ])
        do {
            try await makeDispatcher(makeClient(transport), sleeper: sleeper)
                .dispatch(workflow: "hello-m3.yml", inputs: [:])
            XCTFail("expected workflowNotSyncedYet")
        } catch let error as GitHubAPIError {
            XCTAssertEqual(error, .workflowNotSyncedYet)
            XCTAssertTrue(error.userMessage.contains("default branch"))
        }
        XCTAssertEqual(sleeper.recorded, [5])
    }

    // MARK: - Token (SKILL.md 7.B)

    func testMissingTokenFailsBeforeAnyRequest() async throws {
        let transport = MockGitHubTransport(queue: [])
        let client = GitHubClient(repository: "ddr-ai/deb2ipa", transport: transport,
                                  tokenStore: InMemoryTokenStore())
        do {
            _ = try await client.validateToken()
            XCTFail("expected missingToken")
        } catch let error as GitHubAPIError {
            XCTAssertEqual(error, .missingToken)
        }
        XCTAssertTrue(transport.recordedRequests.isEmpty)
    }

    func testValidateTokenChecksUserAndWorkflowList() async throws {
        let transport = MockGitHubTransport(queue: [
            .success(ok(GitHubFixtures.userJSON)),
            .success(ok(GitHubFixtures.workflowsJSON)),
        ])
        let user = try await makeClient(transport).validateToken()
        XCTAssertEqual(user.login, "ddr-ai")
        XCTAssertEqual(transport.recordedRequests.map(\.path),
                       ["/user", "/repos/ddr-ai/deb2ipa/actions/workflows"])
    }

    func testValidateTokenRejectsBadCredentials() async throws {
        let transport = MockGitHubTransport(queue: [
            .success(response(401, "{\"message\":\"Bad credentials\"}")),
        ])
        do {
            _ = try await makeClient(transport).validateToken()
            XCTFail("expected unauthorized")
        } catch let error as GitHubAPIError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    func testWorkflowsDecodeRealPayload() async throws {
        let transport = MockGitHubTransport(queue: [.success(ok(GitHubFixtures.workflowsJSON))])
        let workflows = try await makeClient(transport).workflows()
        XCTAssertEqual(workflows.count, 1)
        XCTAssertEqual(workflows.first?.path, ".github/workflows/test.yml")
        XCTAssertEqual(workflows.first?.state, "active")
    }

    // MARK: - Runs and polling (SKILL.md 7.J)

    func testRunDecodesRealGitHubPayload() async throws {
        let transport = MockGitHubTransport(queue: [.success(ok(GitHubFixtures.runJSON))])
        let run = try await makeClient(transport).run(40_650_691_548)
        XCTAssertEqual(run.id, 40_650_691_548)
        XCTAssertEqual(run.name, "Tests")
        XCTAssertTrue(run.isCompleted)
        XCTAssertTrue(run.succeeded)
        XCTAssertEqual(run.headSHA, "fb0f6f476b0fa7ecf28617d7e9c78368b1049f3c")
        XCTAssertEqual(run.htmlURL, "https://github.com/ddr-ai/deb2ipa/actions/runs/40650691548")
    }

    func testListRunsDecodesEnvelope() async throws {
        let transport = MockGitHubTransport(queue: [.success(ok(GitHubFixtures.runsListJSON))])
        let runs = try await makeClient(transport).listRuns(workflow: "test.yml", limit: 1)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.id, 40_650_691_548)
    }

    func testRunPollingUsesETagCacheAndBackoff() async throws {
        let sleeper = TestSleeper()
        let transport = MockGitHubTransport(queue: [
            .success(ok(GitHubFixtures.runQueuedJSON, etag: "v1")),
            .success(response(304, "", headers: ["etag": "v1"])),
            .success(ok(GitHubFixtures.runJSON, etag: "v2")),
        ])
        let poller = GitHubRunPoller(client: makeClient(transport), sleeper: sleeper)
        let run = try await poller.awaitCompletion(runID: 40_650_691_548)

        XCTAssertTrue(run.succeeded)
        XCTAssertEqual(transport.recordedRequests.count, 3)
        XCTAssertNil(transport.recordedRequests[0].headers["If-None-Match"])
        XCTAssertEqual(transport.recordedRequests[1].headers["If-None-Match"], "v1")
        XCTAssertEqual(transport.recordedRequests[2].headers["If-None-Match"], "v1")
        XCTAssertEqual(sleeper.recorded, [2, 4])
    }

    func testPollerBackoffCapsAt30Seconds() async throws {
        let sleeper = TestSleeper()
        var queue: [Result<GitHubHTTPResponse, Error>] = []
        for _ in 0..<6 {
            queue.append(.success(ok(GitHubFixtures.runInProgressJSON)))
        }
        queue.append(.success(ok(GitHubFixtures.runJSON)))
        let transport = MockGitHubTransport(queue: queue)
        let poller = GitHubRunPoller(client: makeClient(transport), sleeper: sleeper)
        let run = try await poller.awaitCompletion(runID: 40_650_691_548)
        XCTAssertTrue(run.succeeded)
        XCTAssertEqual(sleeper.recorded, [2, 4, 8, 16, 30, 30])
    }

    func testPollerToleratesNotFoundWhileRunBecomesVisible() async throws {
        let sleeper = TestSleeper()
        let transport = MockGitHubTransport(queue: [
            .success(response(404, "{\"message\":\"Not Found\"}")),
            .success(ok(GitHubFixtures.runJSON)),
        ])
        let poller = GitHubRunPoller(client: makeClient(transport), sleeper: sleeper)
        let run = try await poller.awaitCompletion(runID: 40_650_691_548)
        XCTAssertTrue(run.succeeded)
        XCTAssertEqual(transport.recordedRequests.count, 2)
        XCTAssertEqual(sleeper.recorded, [2])
    }

    func testPollerTimesOutWithTypedError() async throws {
        let sleeper = TestSleeper()
        var queue: [Result<GitHubHTTPResponse, Error>] = []
        for _ in 0..<3 {
            queue.append(.success(ok(GitHubFixtures.runInProgressJSON)))
        }
        let transport = MockGitHubTransport(queue: queue)
        let poller = GitHubRunPoller(client: makeClient(transport), sleeper: sleeper, maxPolls: 3)
        do {
            _ = try await poller.awaitCompletion(runID: 40_650_691_548)
            XCTFail("expected pollingTimeout")
        } catch let error as GitHubAPIError {
            XCTAssertEqual(error, .pollingTimeout(maxPolls: 3))
        }
        XCTAssertEqual(sleeper.recorded, [2, 4])
    }

    func testFailedRunFetchesLogs() async throws {
        let transport = MockGitHubTransport(queue: [
            .success(ok(GitHubFixtures.runFailedJSON)),
            .success(ok("fake log bytes")),
        ])
        let client = makeClient(transport)
        let run = try await client.run(40_650_691_548)
        XCTAssertFalse(run.succeeded)
        XCTAssertEqual(run.conclusion, "failure")
        let logs = try await client.logs(runID: run.id)
        XCTAssertEqual(logs, Data("fake log bytes".utf8))
        XCTAssertEqual(transport.recordedRequests.last?.path,
                       "/repos/ddr-ai/deb2ipa/actions/runs/40650691548/logs")
    }

    func testRateLimitSurfacesResetEpoch() async throws {
        let transport = MockGitHubTransport(queue: [
            .success(response(403, "{\"message\":\"API rate limit exceeded\"}", headers: [
                "x-ratelimit-remaining": "0",
                "x-ratelimit-reset": "1790000000",
            ])),
        ])
        do {
            _ = try await makeClient(transport).run(40_650_691_548)
            XCTFail("expected rateLimited")
        } catch let error as GitHubAPIError {
            XCTAssertEqual(error, .rateLimited(resetEpoch: 1_790_000_000))
        }
    }

    func testUnexpectedStatusMapsToTypedHTTPError() async throws {
        let transport = MockGitHubTransport(queue: [
            .success(response(500, "{\"message\":\"Server error\"}")),
        ])
        do {
            _ = try await makeClient(transport).run(40_650_691_548)
            XCTFail("expected http error")
        } catch let error as GitHubAPIError {
            XCTAssertEqual(error, .http(500, "Server error"))
        }
    }

    func testMalformedJSONSurfacesDecodingError() async throws {
        let transport = MockGitHubTransport(queue: [.success(ok("{not json"))])
        do {
            _ = try await makeClient(transport).run(40_650_691_548)
            XCTFail("expected decoding error")
        } catch let error as GitHubAPIError {
            guard case .decoding = error else {
                return XCTFail("expected decoding, got \(error)")
            }
        }
    }

    // MARK: - Releases and assets

    func testReleasesDecodeRealPayload() async throws {
        let transport = MockGitHubTransport(queue: [.success(ok(GitHubFixtures.releaseListJSON))])
        let releases = try await makeClient(transport).releases()
        XCTAssertEqual(releases.count, 1)
        let release = try XCTUnwrap(releases.first)
        XCTAssertEqual(release.tagName, "v2.338.2")
        XCTAssertEqual(release.assets.count, 2)
        let asset = try XCTUnwrap(release.assets.first)
        XCTAssertEqual(asset.name, "actions-runner-linux-arm-2.338.2.tar.gz")
        XCTAssertEqual(asset.size, 77_599_742)
        XCTAssertEqual(asset.apiPath, "/repos/actions/runner/releases/assets/678461299")
    }

    func testDownloadAssetUsesOctetStreamAccept() async throws {
        let transport = MockGitHubTransport(queue: [.success(ok("IPA-BYTES"))])
        let client = makeClient(transport)
        let asset = GitHubReleaseAsset(
            id: 678_461_299,
            name: "app.ipa",
            contentType: "application/octet-stream",
            size: 9,
            url: "https://api.github.com/repos/ddr-ai/deb2ipa/releases/assets/678461299",
            browserDownloadURL: "https://github.com/ddr-ai/deb2ipa/releases/download/v1/app.ipa")
        let data = try await client.download(asset)
        XCTAssertEqual(data, Data("IPA-BYTES".utf8))
        let sent = try XCTUnwrap(transport.recordedRequests.first)
        XCTAssertEqual(sent.path, "/repos/ddr-ai/deb2ipa/releases/assets/678461299")
        XCTAssertEqual(sent.headers["Accept"], "application/octet-stream")
        XCTAssertEqual(sent.headers["Authorization"], "Bearer ghp_test_pat")
    }

    // MARK: - Build request input contract

    func testBuildDispatchRequestInputsContract() async throws {
        let request = BuildDispatchRequest(
            debURL: "https://example.org/app.deb",
            packageName: "com.example.app",
            version: "1.0-1",
            repos: ["https://repo.chariz.com/", "https://havoc.app/"])
        let inputs = try request.inputs()
        XCTAssertEqual(inputs["deb_url"], "https://example.org/app.deb")
        XCTAssertEqual(inputs["package_name"], "com.example.app")
        XCTAssertEqual(inputs["version"], "1.0-1")
        XCTAssertNil(inputs["bundle_id"])
        XCTAssertNil(inputs["display_name"])
        XCTAssertNil(inputs["extra_debs"])
        let repos = try JSONDecoder().decode(
            [String].self, from: Data(try XCTUnwrap(inputs["repos"]).utf8))
        XCTAssertEqual(repos, ["https://repo.chariz.com/", "https://havoc.app/"])

        let full = BuildDispatchRequest(
            debURL: "https://example.org/app.deb",
            packageName: "com.example.app",
            version: "1.0-1",
            bundleID: "com.example.app",
            displayName: "Example",
            repos: ["https://repo.chariz.com/"],
            extraDebURLs: ["https://example.org/lib.deb"])
        let fullInputs = try full.inputs()
        XCTAssertEqual(fullInputs["bundle_id"], "com.example.app")
        XCTAssertEqual(fullInputs["display_name"], "Example")
        let extras = try JSONDecoder().decode(
            [String].self, from: Data(try XCTUnwrap(fullInputs["extra_debs"]).utf8))
        XCTAssertEqual(extras, ["https://example.org/lib.deb"])
    }

    // MARK: - Token store

    func testInMemoryTokenStoreRoundTrip() throws {
        let store = InMemoryTokenStore()
        XCTAssertNil(try store.load())
        try store.save("token-a")
        XCTAssertEqual(try store.load(), "token-a")
        try store.clear()
        XCTAssertNil(try store.load())
    }
}
