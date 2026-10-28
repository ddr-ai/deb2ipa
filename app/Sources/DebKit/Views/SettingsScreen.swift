#if canImport(SwiftUI)
import SwiftUI

/// Settings screen: PAT management (Keychain), conversion repository,
/// apt repos, workflow file, and the default IPA handoff target.
public struct SettingsScreen: View {
    @ObservedObject var environment: AppEnvironment

    @State private var tokenDraft = ""
    @State private var repositoryDraft = ""
    @State private var workflowDraft = ""
    @State private var newRepo = ""

    public var body: some View {
        NavigationStack {
            Form {
                tokenSection
                repositorySection
                reposSection
                installTargetSection
                aboutSection
            }
            .navigationTitle("Settings")
            .onAppear {
                repositoryDraft = environment.preferences.repository
                workflowDraft = environment.preferences.workflowFile
            }
        }
    }

    // MARK: - Token

    private var tokenSection: some View {
        Section {
            switch environment.tokenStatus {
            case .valid(let login):
                Label("Signed in as \(login)", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            case .checking:
                HStack { ProgressView(); Text("Checking token…").padding(.leading, 8) }
            case .invalid(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            case .missing:
                Label("No token saved", systemImage: "key.slash")
                    .foregroundStyle(.secondary)
            case .unknown:
                Label("Token not checked yet", systemImage: "key")
                    .foregroundStyle(.secondary)
            }

            if environment.tokenStatus.isNotValid {
                SecureField("GitHub PAT (fine-grained)", text: $tokenDraft)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Save and validate") {
                    let token = tokenDraft
                    tokenDraft = ""
                    Task { await environment.saveToken(token) }
                }
                .disabled(tokenDraft.isEmpty)
            }

            if environment.tokenStatus.hasToken {
                Button("Re-validate", role: .none) {
                    Task { await environment.validateToken() }
                }
                Button("Remove token", role: .destructive) {
                    environment.clearToken()
                }
            }
        } header: {
            Text("GitHub token")
        } footer: {
            Text("A fine-grained PAT with Contents and Actions read+write on the "
                 + "conversion repository. It is stored in the iOS Keychain "
                 + "(ThisDeviceOnly) and never leaves the device.")
        }
    }

    // MARK: - Repository / workflow

    private var repositorySection: some View {
        Section {
            TextField("owner/repo", text: $repositoryDraft)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField("build-ipa.yml", text: $workflowDraft)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Save") {
                let repo = repositoryDraft.trimmingCharacters(in: .whitespaces)
                let workflow = workflowDraft.trimmingCharacters(in: .whitespaces)
                guard !repo.isEmpty, !workflow.isEmpty else { return }
                environment.updatePreferences { prefs in
                    prefs.repository = repo
                    prefs.workflowFile = workflow
                }
            }
            .disabled(repositoryDraft.isEmpty || workflowDraft.isEmpty)
        } header: {
            Text("Conversion repository")
        } footer: {
            Text("The fork or repository whose build-ipa workflow converts your "
                 + "debs; the workflow file is dispatched via workflow_dispatch.")
        }
    }

    // MARK: - Repos

    private var reposSection: some View {
        Section {
            ForEach(environment.preferences.repos, id: \.self) { repo in
                Text(repo).font(.caption.monospaced())
            }
            .onDelete { offsets in
                environment.updatePreferences { prefs in
                    prefs.repos.remove(atOffsets: offsets)
                }
            }
            ForEach(AppPreferences.knownRepos, id: \.self) { known in
                if !environment.preferences.repos.contains(known) {
                    Button {
                        environment.updatePreferences { prefs in
                            prefs.repos.append(known)
                        }
                    } label: {
                        Label(known, systemImage: "plus.circle")
                            .font(.caption.monospaced())
                    }
                }
            }
            HStack {
                TextField("https://apt.example.com/", text: $newRepo)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Add") {
                    let repo = newRepo.trimmingCharacters(in: .whitespaces)
                    guard !repo.isEmpty else { return }
                    environment.updatePreferences { prefs in
                        if !prefs.repos.contains(repo) { prefs.repos.append(repo) }
                    }
                    newRepo = ""
                }
                .disabled(newRepo.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Dependency repos")
        } footer: {
            Text("Apt repos the resolver searches for the deb's dependency "
                 + "closure. Swipe to remove.")
        }
    }

    // MARK: - Install target

    private var installTargetSection: some View {
        Section {
            Picker("Default handoff", selection: Binding(
                get: { environment.preferences.installTarget },
                set: { target in
                    environment.updatePreferences { prefs in
                        prefs.installTarget = target
                    }
                })) {
                ForEach(InstallTarget.allCases, id: \.self) { target in
                    Text(target.label).tag(target)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("IPA handoff")
        } footer: {
            Text("The share sheet works with every sideload tool (the IPA is "
                 + "unsigned; AltStore, Sideloadly & co. sign it with your Apple "
                 + "ID). AltStore's one-tap path uses its altstore:// scheme.")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("deb2ipa", value: "unsigned by design")
            if let url = URL(string: "https://github.com/"
                + environment.preferences.repository) {
                Link("Project on GitHub", destination: url)
            }
        }
    }
}

private extension AppEnvironment.TokenStatus {
    /// True for the states that make the "paste a token" field useful.
    var isNotValid: Bool {
        switch self {
        case .valid: return false
        case .unknown, .missing, .checking, .invalid: return true
        }
    }

    /// True when a token is stored (valid or not yet re-checked).
    var hasToken: Bool {
        switch self {
        case .valid, .invalid: return true
        case .unknown, .missing, .checking: return false
        }
    }
}
#endif
