import Foundation

/// App-level preferences (Settings screen). The PAT deliberately lives in
/// the Keychain (`KeychainTokenStore`), never here.
public struct AppPreferences: Equatable, Codable, Sendable {
    /// Repository hosting the conversion workflow, "owner/repo".
    public var repository: String
    /// Workflow file name dispatched on convert.
    public var workflowFile: String
    /// apt repos the resolver runs against (JSON array input `repos`).
    public var repos: [String]
    /// What happens with a finished IPA.
    public var installTarget: InstallTarget

    public init(repository: String = AppPreferences.defaultRepository,
                workflowFile: String = AppPreferences.defaultWorkflowFile,
                repos: [String] = AppPreferences.defaultRepos,
                installTarget: InstallTarget = .ask) {
        self.repository = repository
        self.workflowFile = workflowFile
        self.repos = repos
        self.installTarget = installTarget
    }

    /// The deb2ipa repository this project ships with.
    public static let defaultRepository = "ddr-ai/deb2ipa"
    public static let defaultWorkflowFile = "build-ipa.yml"
    /// Mirrors docs/REPOS.md (the workflow's own smoke defaults).
    public static let defaultRepos = [
        "https://repo.chariz.com/",
        "https://apt.procurs.us/dists/iphoneos-arm64-rootless/1800/main/binary-iphoneos-arm64/",
    ]
    /// Curated repo list offered as quick-add chips in Settings.
    public static let knownRepos = [
        "https://repo.chariz.com/",
        "https://apt.procurs.us/dists/iphoneos-arm64-rootless/1800/main/binary-iphoneos-arm64/",
        "https://apt.procurs.us/dists/iphoneos-arm64/1800/main/binary-iphoneos-arm64/",
    ]

    public static let `default` = AppPreferences()

    /// Validated "owner/repo" shape for the repository field.
    public var repositoryLooksValid: Bool {
        let parts = repository.split(separator: "/")
        return parts.count == 2
            && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { ($0.isLetter || $0.isNumber) || $0 == "-" || $0 == "_" || $0 == "." } }
    }

    /// The workflow file with ".github/workflows/" stripped, as the
    /// dispatch API expects it.
    public var workflowBasename: String {
        workflowFile.split(separator: "/").last.map(String.init) ?? workflowFile
    }
}

/// Persistence seam so preferences can round-trip in tests without
/// touching real storage on the Linux CI.
public protocol PreferencesStore: Sendable {
    func save(_ preferences: AppPreferences) throws
    func load() throws -> AppPreferences?
}

/// In-memory store for tests and previews.
public final class InMemoryPreferencesStore: PreferencesStore, @unchecked Sendable {
    private let lock = NSLock()
    private var prefs: AppPreferences?

    public init(preferences: AppPreferences? = nil) {
        self.prefs = preferences
    }

    public func save(_ preferences: AppPreferences) {
        lock.lock(); defer { lock.unlock() }
        prefs = preferences
    }

    public func load() -> AppPreferences? {
        lock.lock(); defer { lock.unlock() }
        return prefs
    }
}

/// UserDefaults-backed store (JSON blob under one key). Used on device;
/// the Linux CI tests use the in-memory store.
public struct UserDefaultsPreferencesStore: PreferencesStore {
    public static let key = "com.dain.deb2ipa.preferences"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func save(_ preferences: AppPreferences) throws {
        let data = try JSONEncoder().encode(preferences)
        defaults.set(data, forKey: Self.key)
    }

    public func load() -> AppPreferences? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(AppPreferences.self, from: data)
    }
}
