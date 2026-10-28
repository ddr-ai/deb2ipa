#if canImport(SwiftUI)
import SwiftUI

/// Builds screen: live state of the conversion kicked off from Import.
/// The BuildCoordinator already narrates dispatch -> discovery -> polling;
/// this screen renders the phase and links out to GitHub.
public struct BuildScreen: View {
    @ObservedObject var environment: AppEnvironment
    @ObservedObject var store: BuildStore
    var openReleases: () -> Void

    public var body: some View {
        NavigationStack {
            Form {
                switch store.phase {
                case .idle:
                    idleSection
                case .converting:
                    Section {
                        HStack {
                            ProgressView()
                            Text(store.phase.title)
                                .padding(.leading, 8)
                        }
                        Text("Dispatching, discovering the run, and polling GitHub. "
                             + "Typical conversions take two to five minutes; this "
                             + "screen updates when the run finishes.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                case .succeeded(let run):
                    Section {
                        Label(store.phase.title,
                              systemImage: run.succeeded
                                ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(run.succeeded ? .green : .red)
                            .font(.headline)
                        if let title = run.name {
                            LabeledContent("Workflow", value: title)
                        }
                        LabeledContent("Status",
                                      value: "\(run.status) — \(run.conclusion ?? "unknown")")
                        if let url = run.htmlURL, let github = URL(string: url) {
                            Link("Open the run on GitHub", destination: github)
                        }
                    }
                    if run.succeeded {
                        Section {
                            Button {
                                openReleases()
                            } label: {
                                Label("Go to Releases to install the IPA",
                                      systemImage: "arrow.down.circle")
                            }
                        }
                    } else {
                        Section {
                            Text("The run finished red. The workflow leaves a draft "
                                 + "release with the full resolution and launchability "
                                 + "reports attached - open the run on GitHub to read them.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                case .failed(let message):
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("Check Settings: the PAT needs Contents and Actions "
                             + "read+write on the conversion repository.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Builds")
        }
    }

    private var idleSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label("No conversion running", systemImage: "sparkles")
                Text("Import a deb, paste its URL, and tap “Convert on GitHub”. "
                     + "The run appears here while it executes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}
#endif
