import Foundation
@testable import DebKit

/// Scripted transport: every send pops the next queued response and records
/// the request for assertions. No network, fully deterministic.
final class MockGitHubTransport: GitHubTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Result<GitHubHTTPResponse, Error>]
    private var received: [GitHubHTTPRequest] = []

    var recordedRequests: [GitHubHTTPRequest] {
        lock.lock(); defer { lock.unlock() }
        return received
    }

    init(queue: [Result<GitHubHTTPResponse, Error>]) {
        self.queue = queue
    }

    func send(_ request: GitHubHTTPRequest) async throws -> GitHubHTTPResponse {
        lock.lock(); defer { lock.unlock() }
        received.append(request)
        guard !queue.isEmpty else {
            throw GitHubAPIError.network("mock transport queue is empty - the test needed another response")
        }
        return try queue.removeFirst().get()
    }
}

/// Records the delays it is asked to sleep instead of sleeping.
final class TestSleeper: GitHubSleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var delays: [Double] = []

    var recorded: [Double] {
        lock.lock(); defer { lock.unlock() }
        return delays
    }

    func sleep(seconds: Double) async {
        lock.lock(); defer { lock.unlock() }
        delays.append(seconds)
    }
}
