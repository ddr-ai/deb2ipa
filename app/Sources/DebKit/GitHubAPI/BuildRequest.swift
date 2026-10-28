import Foundation

/// A build request the app sends to build-ipa.yml via workflow_dispatch.
/// The input names are the contract with the M4 workflow (SKILL.md section 4):
/// deb_url, package_name, version, bundle_id, display_name, repos, extra_debs.
public struct BuildDispatchRequest: Equatable, Sendable {
    public var debURL: String
    public var packageName: String
    public var version: String
    public var bundleID: String?
    public var displayName: String?
    public var repos: [String]
    public var extraDebURLs: [String]

    public init(debURL: String, packageName: String, version: String,
                bundleID: String? = nil, displayName: String? = nil,
                repos: [String] = [], extraDebURLs: [String] = []) {
        self.debURL = debURL
        self.packageName = packageName
        self.version = version
        self.bundleID = bundleID
        self.displayName = displayName
        self.repos = repos
        self.extraDebURLs = extraDebURLs
    }

    /// workflow_dispatch inputs must all be strings. Always present:
    /// deb_url, package_name, version, repos (a JSON array). Present only
    /// when set and non-empty: bundle_id, display_name, extra_debs (JSON
    /// array) - optional inputs stay unset in the workflow.
    public func inputs() throws -> [String: String] {
        var inputs: [String: String] = [:]
        inputs["deb_url"] = debURL
        inputs["package_name"] = packageName
        inputs["version"] = version
        inputs["repos"] = try jsonString(repos)
        if let bundleID, !bundleID.isEmpty {
            inputs["bundle_id"] = bundleID
        }
        if let displayName, !displayName.isEmpty {
            inputs["display_name"] = displayName
        }
        if !extraDebURLs.isEmpty {
            inputs["extra_debs"] = try jsonString(extraDebURLs)
        }
        return inputs
    }

    private func jsonString(_ values: [String]) throws -> String {
        let data: Data
        do {
            data = try JSONEncoder().encode(values)
        } catch {
            throw GitHubAPIError.encoding("failed to encode input list: \(error)")
        }
        guard let string = String(data: data, encoding: .utf8) else {
            throw GitHubAPIError.encoding("encoded input list was not valid UTF-8")
        }
        return string
    }
}
