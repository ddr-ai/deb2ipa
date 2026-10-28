import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One HTTP exchange with the GitHub REST API, abstracted so unit tests can
/// replay scripted responses without any network.
public struct GitHubHTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, path: String,
                headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

/// Response headers use LOWERCASE keys.
public struct GitHubHTTPResponse: Equatable, Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public protocol GitHubTransport: Sendable {
    func send(_ request: GitHubHTTPRequest) async throws -> GitHubHTTPResponse
}

/// Every failure the GitHub client can surface, each carrying a human-readable
/// message for the M6 UI. 401/403 mapping per SKILL.md 7.B; rate-limit
/// detection per 7.J; workflow-not-synced per 7.A.
public enum GitHubAPIError: Error, Equatable, Sendable {
    /// No PAT is saved at all.
    case missingToken
    /// 401: the PAT is invalid, revoked, or expired.
    case unauthorized
    /// 403/429 outside rate limiting.
    case forbidden(String)
    /// 403/429 with X-RateLimit-Remaining: 0.
    case rateLimited(resetEpoch: Int64)
    /// 404 outside the dispatch retry path.
    case notFound
    /// Dispatch retried once on 404/422 and still failed (SKILL.md 7.A).
    case workflowNotSyncedYet
    /// 422 outside the dispatch retry path.
    case validationFailed(String)
    /// The run did not finish within the poll budget.
    case pollingTimeout(maxPolls: Int)
    /// Any other unexpected status.
    case http(Int, String)
    /// Transport-level failure (offline, DNS, TLS...).
    case network(String)
    case encoding(String)
    case decoding(String)

    public var userMessage: String {
        switch self {
        case .missingToken:
            return "No GitHub token is saved. Add your personal access token in Settings."
        case .unauthorized:
            return "GitHub rejected the token (401). Check that your PAT is valid and not expired."
        case .forbidden(let message):
            return "GitHub denied the request (403): \(message)"
        case .rateLimited(let resetEpoch):
            let reset = Date(timeIntervalSince1970: TimeInterval(resetEpoch))
            let formatted = ISO8601DateFormatter().string(from: reset)
            return "GitHub API rate limit reached; resets at \(formatted)."
        case .notFound:
            return "Not found (404). Check the repository name."
        case .workflowNotSyncedYet:
            return "The workflow file is not on the default branch yet (wait a few seconds and retry), or the repository or workflow name is wrong."
        case .validationFailed(let message):
            return "GitHub rejected the request (422): \(message)"
        case .pollingTimeout(let maxPolls):
            return "The build did not finish within the polling budget (\(maxPolls) attempts)."
        case .http(let status, let message):
            return "Unexpected GitHub response (HTTP \(status)): \(message)"
        case .network(let message):
            return "Network error: \(message)"
        case .encoding(let message):
            return "Could not encode the request: \(message)"
        case .decoding(let message):
            return "Could not understand GitHub's response: \(message)"
        }
    }
}

/// Production transport over URLSession. Works on iOS/macOS natively and on
/// Linux via FoundationNetworking; redirects (e.g. the run-logs 302 to a
/// signed URL) are followed automatically.
public struct URLSessionTransport: GitHubTransport {
    public static let defaultBaseURLString = "https://api.github.com"

    private let baseURLString: String

    public init(baseURLString: String = URLSessionTransport.defaultBaseURLString) {
        self.baseURLString = baseURLString
    }

    public func send(_ request: GitHubHTTPRequest) async throws -> GitHubHTTPResponse {
        guard let url = URL(string: baseURLString + request.path) else {
            throw GitHubAPIError.network("invalid request URL: \(baseURLString)\(request.path)")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            throw GitHubAPIError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw GitHubAPIError.network("non-HTTP response from \(url.absoluteString)")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let name = key as? String, let value = value as? String {
                headers[name.lowercased()] = value
            }
        }
        return GitHubHTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }
}
