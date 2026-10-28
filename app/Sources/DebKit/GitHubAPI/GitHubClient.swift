import Foundation

/// The small slice of the GitHub REST API deb2ipa needs: token validation
/// (SKILL.md 7.B), workflow dispatch (the 7.A retry lives in
/// GitHubDispatcher), run polling with ETag caching (7.J), failure logs,
/// and release assets.
///
/// An actor so the ETag cache is safe under concurrent pollers.
public actor GitHubClient {
    private let repository: String
    private let transport: GitHubTransport
    private let tokenStore: GitHubTokenStore

    /// ETag cache: GitHub documents that conditional requests answered with
    /// 304 do NOT count against the rate limit (SKILL.md 7.J).
    private var etags: [String: String] = [:]
    private var cachedBodies: [String: Data] = [:]

    public init(repository: String, transport: GitHubTransport, tokenStore: GitHubTokenStore) {
        self.repository = repository
        self.transport = transport
        self.tokenStore = tokenStore
    }

    // MARK: Token validation (SKILL.md 7.B)

    /// Validates the stored PAT: GET /user plus the repo workflow list,
    /// the same access the app needs for dispatch and polling.
    public func validateToken() async throws -> GitHubUser {
        let user: GitHubUser = try await getDecodable("/user")
        _ = try await workflows()
        return user
    }

    public func workflows() async throws -> [GitHubWorkflow] {
        try await getDecodable("/repos/\(repository)/actions/workflows")
    }

    // MARK: Workflow dispatch

    /// POSTs a workflow_dispatch (204 on success). Retrying on 404/422 is
    /// GitHubDispatcher's job, not the client's.
    public func dispatch(workflow: String, ref: String, inputs: [String: String]) async throws {
        let body: Data
        do {
            body = try JSONEncoder().encode(GitHubDispatchPayload(ref: ref, inputs: inputs))
        } catch {
            throw GitHubAPIError.encoding("failed to encode dispatch payload: \(error)")
        }
        _ = try await perform(
            "POST",
            "/repos/\(repository)/actions/workflows/\(workflow)/dispatches",
            body: body)
    }

    // MARK: Runs

    /// Fetches a run; ETag-cached, so tight polling costs almost no rate
    /// limit while the run body is unchanged.
    public func run(_ id: Int64) async throws -> GitHubWorkflowRun {
        try await getDecodable("/repos/\(repository)/actions/runs/\(id)", cacheable: true)
    }

    /// The most recent runs of a workflow (newest first).
    public func listRuns(workflow: String, limit: Int = 5) async throws -> [GitHubWorkflowRun] {
        let envelope: GitHubRunEnvelope = try await getDecodable(
            "/repos/\(repository)/actions/workflows/\(workflow)/runs?per_page=\(limit)")
        return envelope.workflowRuns
    }

    /// The run's log archive. The API answers with a 302 to a signed URL;
    /// URLSession follows the redirect automatically.
    public func logs(runID: Int64) async throws -> Data {
        try await perform("GET", "/repos/\(repository)/actions/runs/\(runID)/logs").body
    }

    // MARK: Releases

    public func releases() async throws -> [GitHubRelease] {
        try await getDecodable("/repos/\(repository)/releases?per_page=20")
    }

    public func release(tag: String) async throws -> GitHubRelease {
        try await getDecodable("/repos/\(repository)/releases/tags/\(tag)")
    }

    /// Downloads an asset's bytes via the API URL with the octet-stream
    /// Accept header - it authenticates and also works on private repos.
    public func download(_ asset: GitHubReleaseAsset) async throws -> Data {
        guard let path = asset.apiPath else {
            throw GitHubAPIError.decoding("release asset has no API URL: \(asset.name)")
        }
        return try await perform("GET", path, headers: ["Accept": "application/octet-stream"]).body
    }

    // MARK: Plumbing

    private func getDecodable<T: Decodable>(_ path: String, cacheable: Bool = false) async throws -> T {
        let response = try await perform("GET", path, cacheable: cacheable)
        do {
            return try JSONDecoder().decode(T.self, from: response.body)
        } catch {
            throw GitHubAPIError.decoding("failed to decode \(T.self) from \(path): \(error)")
        }
    }

    private func perform(_ method: String, _ path: String, body: Data? = nil,
                         headers: [String: String] = [:],
                         cacheable: Bool = false) async throws -> GitHubHTTPResponse {
        guard let token = try tokenStore.load(), !token.isEmpty else {
            throw GitHubAPIError.missingToken
        }
        var allHeaders: [String: String] = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "deb2ipa",
        ]
        for (name, value) in headers {
            allHeaders[name] = value
        }
        if body != nil {
            allHeaders["Content-Type"] = "application/json"
        }

        var request = GitHubHTTPRequest(method: method, path: path, headers: allHeaders, body: body)
        if cacheable, method == "GET", let etag = etags[path] {
            request.headers["If-None-Match"] = etag
        }

        let response: GitHubHTTPResponse
        do {
            response = try await transport.send(request)
        } catch let error as GitHubAPIError {
            throw error
        } catch {
            throw GitHubAPIError.network(String(describing: error))
        }

        // 304 Not Modified: serve the cached body. GitHub does not count
        // these against the rate limit (SKILL.md 7.J).
        if cacheable, response.statusCode == 304, let cached = cachedBodies[path] {
            return GitHubHTTPResponse(statusCode: 200, headers: [:], body: cached)
        }

        let checked = try mapErrors(response)
        if cacheable, response.statusCode == 200 {
            etags[path] = response.headers["etag"]
            if response.headers["etag"] != nil {
                cachedBodies[path] = response.body
            }
        }
        return checked
    }

    /// Maps non-2xx statuses to typed errors (SKILL.md 7.B / 7.J).
    private func mapErrors(_ response: GitHubHTTPResponse) throws -> GitHubHTTPResponse {
        switch response.statusCode {
        case 200..<300:
            return response
        case 401:
            throw GitHubAPIError.unauthorized
        case 403, 429:
            if response.headers["x-ratelimit-remaining"] == "0" {
                let reset = Int64(response.headers["x-ratelimit-reset"] ?? "") ?? 0
                throw GitHubAPIError.rateLimited(resetEpoch: reset)
            }
            throw GitHubAPIError.forbidden(envelopeMessage(response))
        case 404:
            throw GitHubAPIError.notFound
        case 422:
            throw GitHubAPIError.validationFailed(envelopeMessage(response))
        default:
            throw GitHubAPIError.http(response.statusCode, envelopeMessage(response))
        }
    }

    private func envelopeMessage(_ response: GitHubHTTPResponse) -> String {
        guard let envelope = try? JSONDecoder().decode(GitHubErrorEnvelope.self, from: response.body),
              let message = envelope.message else {
            return String(data: response.body, encoding: .utf8) ?? "<no body>"
        }
        return message
    }
}

private struct GitHubDispatchPayload: Encodable {
    let ref: String
    let inputs: [String: String]
}

private struct GitHubRunEnvelope: Decodable {
    let workflowRuns: [GitHubWorkflowRun]
    private enum CodingKeys: String, CodingKey { case workflowRuns = "workflow_runs" }
}

private struct GitHubErrorEnvelope: Decodable {
    let message: String?
}
