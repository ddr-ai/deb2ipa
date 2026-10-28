#if canImport(SwiftUI)
import Foundation
import SwiftUI

// The observable stores glue the pure M6 logic (import pipeline, overview,
// dependency display, BuildCoordinator, Sideload) to the SwiftUI screens.
// Everything here is Apple-platform-only; the logic itself runs (and is
// tested) on the Linux CI.

// MARK: - App environment

/// The shared root object: preferences, token state, and client factory.
@MainActor
public final class AppEnvironment: ObservableObject {

    public enum TokenStatus: Equatable {
        case unknown
        case missing
        case checking
        case valid(String)
        case invalid(String)

        public var label: String {
            switch self {
            case .unknown: return "Not checked yet"
            case .missing: return "No token saved"
            case .checking: return "Checking token…"
            case .valid(let login): return "Signed in as \(login)"
            case .invalid: return "Token rejected"
            }
        }
    }

    @Published public private(set) var preferences: AppPreferences
    @Published public private(set) var tokenStatus: TokenStatus = .unknown

    private let preferencesStore: PreferencesStore
    private let tokenStore: GitHubTokenStore

    public init(preferencesStore: PreferencesStore = UserDefaultsPreferencesStore(),
                tokenStore: GitHubTokenStore = KeychainTokenStore()) {
        self.preferencesStore = preferencesStore
        self.tokenStore = tokenStore
        self.preferences = (try? preferencesStore.load()) ?? .default
    }

    /// A client bound to the current repository and saved token.
    /// Returns nil when no token is saved (callers surface the Settings
    /// screen instead of crashing).
    public func makeClient() -> GitHubClient? {
        guard (try? tokenStore.load()) != nil else { return nil }
        return GitHubClient(repository: preferences.repository,
                            transport: URLSessionTransport(),
                            tokenStore: tokenStore)
    }

    public func updatePreferences(_ update: (inout AppPreferences) -> Void) {
        var prefs = preferences
        update(&prefs)
        preferences = prefs
        try? preferencesStore.save(prefs)
    }

    public func replacePreferences(_ prefs: AppPreferences) {
        preferences = prefs
        try? preferencesStore.save(prefs)
    }

    /// Saves the PAT to the Keychain and validates it against the API.
    public func saveToken(_ token: String) async {
        guard !token.isEmpty else { return }
        do {
            try tokenStore.save(token)
            await validateToken()
        } catch {
            tokenStatus = .invalid("The token could not be saved: \(error.localizedDescription)")
        }
    }

    public func clearToken() {
        try? tokenStore.clear()
        tokenStatus = .missing
    }

    /// Validates the saved token (GET /user) and records the login.
    public func validateToken() async {
        guard (try? tokenStore.load()) != nil else {
            tokenStatus = .missing
            return
        }
        tokenStatus = .checking
        guard let client = makeClient() else {
            tokenStatus = .missing
            return
        }
        do {
            let user = try await client.validateToken()
            tokenStatus = .valid(user.login)
        } catch let error as GitHubAPIError {
            tokenStatus = .invalid(error.userMessage)
        } catch {
            tokenStatus = .invalid(error.localizedDescription)
        }
    }
}

// MARK: - Import

/// Import tab state: local file inspection + the deb URL the conversion
/// needs. The file parse powers the metadata/depends cards; the URL drives
/// the workflow dispatch.
@MainActor
public final class ImportStore: ObservableObject {

    public enum State: Equatable {
        case empty
        case importing
        case imported(DebOverview, [DependencySection])
        case failed(String)
    }

    @Published public private(set) var state: State = .empty
    /// The deb URL the workflow will download. A local file import fills
    /// the metadata cards but cannot be converted without a URL.
    @Published public var debURLText: String = ""
    @Published public var isFileImporterPresented = false

    /// True when `debURLText` is an http(s) URL the workflow can fetch.
    public var hasConvertURL: Bool {
        if let url = URL(string: debURLText.trimmingCharacters(in: .whitespacesAndNewlines)),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           url.host != nil {
            return true
        }
        return false
    }

    public func importFile(at url: URL) {
        state = .importing
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                DebImporter.importDeb(from: url)
            }.value
            apply(outcome: outcome)
        }
    }

    public func importData(_ data: Data, filename: String?) {
        state = .importing
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                DebImporter.importDeb(data: data, filename: filename)
            }.value
            apply(outcome: outcome)
        }
    }

    private func apply(outcome: ImportOutcome) {
        switch outcome {
        case .imported(let package, let classification):
            let overview = DebOverview(control: package.control,
                                       classification: classification,
                                       debSizeBytes: 0)
            let sections = DependencyDisplay.sections(for: package.control)
            state = .imported(overview, sections)
        case .failed(let failure):
            state = .failed(failure.userMessage)
        }
    }

    /// The dispatch request for "Convert on GitHub": requires a URL; the
    /// imported package (when available) prefills name and version so the
    /// release metadata is right even before the runner parses the deb.
    public func buildRequest(preferences: AppPreferences) -> BuildDispatchRequest? {
        guard hasConvertURL else { return nil }
        var packageName = ""
        var version = ""
        var displayName: String?
        if case .imported(let overview, _) = state {
            packageName = overview.packageID
            version = overview.version
            displayName = overview.title
        }
        return BuildDispatchRequest(
            debURL: debURLText.trimmingCharacters(in: .whitespacesAndNewlines),
            packageName: packageName,
            version: version,
            bundleID: nil,
            displayName: displayName,
            repos: preferences.repos,
            extraDebURLs: [])
    }

    public func reset() {
        state = .empty
        debURLText = ""
    }
}

// MARK: - Build

/// Builds tab: one conversion at a time, driven by BuildCoordinator.
@MainActor
public final class BuildStore: ObservableObject {

    public enum Phase: Equatable {
        case idle
        case converting
        case succeeded(GitHubWorkflowRun)
        case failed(String)

        public var title: String {
            switch self {
            case .idle: return "No conversion running"
            case .converting: return "Converting on GitHub…"
            case .succeeded(let run):
                return run.succeeded ? "Conversion succeeded" : "Conversion run failed"
            case .failed: return "Conversion failed"
            }
        }
    }

    @Published public private(set) var phase: Phase = .idle

    public func start(request: BuildDispatchRequest,
                      preferences: AppPreferences,
                      environment: AppEnvironment) async {
        guard let client = environment.makeClient() else {
            phase = .failed("No GitHub token is saved. Add a PAT in Settings first.")
            return
        }
        let coordinator = BuildCoordinator(
            dispatcher: GitHubDispatcher(client: client),
            client: client,
            poller: GitHubRunPoller(client: client))
        phase = .converting
        let result = await coordinator.convert(request,
                                               workflow: preferences.workflowBasename)
        switch result {
        case .finished(let run):
            phase = .succeeded(run)
        case .failed(let message):
            phase = .failed(message)
        }
    }
}

// MARK: - Releases

/// Releases tab: lists the repository's releases and hands off IPA
/// assets to AltStore or the share sheet.
@MainActor
public final class ReleasesStore: ObservableObject {

    @Published public private(set) var releases: [GitHubRelease] = []
    @Published public private(set) var loadError: String?
    @Published public private(set) var isRefreshing = false

    public func refresh(environment: AppEnvironment) async {
        guard let client = environment.makeClient() else {
            loadError = "No GitHub token is saved. Add a PAT in Settings first."
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            releases = try await client.releases()
            loadError = releases.isEmpty ? "No releases yet." : nil
        } catch let error as GitHubAPIError {
            loadError = error.userMessage
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// The IPA asset of a release, if it carries one.
    public func ipaAsset(in release: GitHubRelease) -> GitHubReleaseAsset? {
        release.assets.first { Sideload.isIPAAsset(named: $0.name) }
    }
}
#endif
