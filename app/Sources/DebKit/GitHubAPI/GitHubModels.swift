import Foundation

/// A workflow run. Only the fields deb2ipa reads are modeled; every other
/// field the API returns is deliberately ignored (the unit tests decode REAL
/// API payloads, full of unknown fields, to keep that honest).
public struct GitHubWorkflowRun: Equatable, Sendable, Codable {
    public let id: Int64
    public let name: String?
    public let status: String
    public let conclusion: String?
    public let htmlURL: String?
    public let createdAt: String?
    public let updatedAt: String?
    public let headSHA: String?

    public var isCompleted: Bool { status == "completed" }
    public var succeeded: Bool { conclusion == "success" }

    private enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion
        case htmlURL = "html_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case headSHA = "head_sha"
    }
}

public struct GitHubUser: Equatable, Sendable, Codable {
    public let login: String
    public let id: Int64
    public let name: String?
}

public struct GitHubWorkflow: Equatable, Sendable, Codable {
    public let id: Int64
    public let name: String?
    public let path: String?
    public let state: String?
}

public struct GitHubRelease: Equatable, Sendable, Codable {
    public let id: Int64
    public let tagName: String
    public let name: String?
    public let draft: Bool?
    public let prerelease: Bool?
    public let htmlURL: String?
    public let assets: [GitHubReleaseAsset]

    private enum CodingKeys: String, CodingKey {
        case id, name, draft, prerelease, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

public struct GitHubReleaseAsset: Equatable, Sendable, Codable {
    public let id: Int64
    public let name: String
    public let contentType: String?
    public let size: Int64
    public let url: String?
    public let browserDownloadURL: String?

    /// The REST path for this asset ("/repos/.../releases/assets/<id>"),
    /// derived from its API URL; nil when the URL is missing or foreign.
    public var apiPath: String? {
        guard let url, let range = url.range(of: "://api.github.com") else { return nil }
        let suffix = url[range.upperBound...]
        return suffix.isEmpty ? nil : String(suffix)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, size, url
        case contentType = "content_type"
        case browserDownloadURL = "browser_download_url"
    }
}
