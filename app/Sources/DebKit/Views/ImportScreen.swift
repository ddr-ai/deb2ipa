#if canImport(SwiftUI)
import SwiftUI
import UniformTypeIdentifiers

/// Import screen: pick (or paste) a deb, inspect its metadata, dependency
/// tree and classification verdict, then send it to the GitHub conversion
/// pipeline. Local files inspect instantly; converting requires an http(s)
/// URL the workflow runner can download (the file itself is too big to
/// pass as a dispatch input).
public struct ImportScreen: View {
    @ObservedObject var environment: AppEnvironment
    @ObservedObject var importStore: ImportStore
    @ObservedObject var buildStore: BuildStore
    /// RootView passes this so "Conversion started" can jump to Builds.
    var openBuilds: () -> Void

    @State private var convertError: String?

    public var body: some View {
        NavigationStack {
            Form {
                debSourceSection
                switch importStore.state {
                case .empty:
                    EmptyStateHint()
                case .importing:
                    HStack { ProgressView(); Text("Parsing…").padding(.leading, 8) }
                case .imported(let overview, let sections):
                    Section("Package") { OverviewCard(overview: overview) }
                    dependencySections(sections)
                    Section("Classification") { ClassificationCard(overview: overview) }
                    convertSection(overview: overview)
                case .failed(let message):
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Import deb")
            .fileImporter(isPresented: $importStore.isFileImporterPresented,
                          // .data, not a deb-specific type: iOS has no
                          // registered .deb UTI, so UTType(filenameExtension:
                          // "deb") is a DYNAMIC type the document picker
                          // cannot match against on-disk file types - deb
                          // files show up greyed-out and unselectable.
                          // public.data matches every real file; DebKit's
                          // ar-magic validation rejects non-debs with the
                          // typed notADeb message instead.
                          allowedContentTypes: [.data],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { importStore.importFile(at: url) }
                case .failure(let error):
                    convertError = error.localizedDescription
                }
            }
            .alert("Could not open the file", isPresented: .init(
                get: { convertError != nil },
                set: { if !$0 { convertError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(convertError ?? "")
            }
        }
    }

    // MARK: - Sections

    private var debSourceSection: some View {
        Section("Deb source") {
            TextField("https://repo.example.com/package.deb",
                      text: $importStore.debURLText)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            Button {
                importStore.isFileImporterPresented = true
            } label: {
                Label("Choose a local .deb to inspect…", systemImage: "doc")
            }

            if case .imported = importStore.state {
                Button(role: .destructive) {
                    importStore.reset()
                } label: {
                    Label("Clear imported package", systemImage: "xmark.circle")
                }
            }
        }
    }

    @ViewBuilder
    private func convertSection(overview: DebOverview) -> some View {
        Section {
            if overview.isConvertible {
                if importStore.hasConvertURL {
                    Button {
                        startConversion()
                    } label: {
                        Label("Convert on GitHub", systemImage: "arrow.triangle.2.circlepath")
                            .font(.headline)
                    }
                    .disabled(buildStore.phase == .converting)
                } else {
                    Label("Add the deb's http(s) URL above to convert it - "
                          + "the GitHub runner downloads the file itself.",
                          systemImage: "link.badge.plus")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("This package is not convertible; see the verdict above.",
                      systemImage: "nosign")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func dependencySections(_ sections: [DependencySection]) -> some View {
        ForEach(sections, id: \.title) { section in
            Section {
                ForEach(section.rows.indices, id: \.self) { index in
                    DependencyRowView(row: section.rows[index])
                }
            } header: {
                Text(section.title)
            }
        }
    }

    private func startConversion() {
        guard let request = importStore.buildRequest(preferences: environment.preferences) else {
            convertError = "The deb URL is not valid."
            return
        }
        Task {
            await buildStore.start(request: request,
                                  preferences: environment.preferences,
                                  environment: environment)
        }
        openBuilds()
    }
}

// MARK: - Pieces

private struct EmptyStateHint: View {
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label("Paste a deb URL, or open a local .deb to inspect it.",
                      systemImage: "info.circle")
                Text("deb2ipa converts any mobile-arm64 .deb into an unsigned IPA "
                     + "on GitHub Actions, then hands it to your sideload tool. "
                     + "You need a PAT in Settings to dispatch builds.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}

private struct OverviewCard: View {
    let overview: DebOverview

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(overview.title).font(.title3.bold())
            Text("\(overview.packageID) — \(overview.version)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let summary = overview.summary {
                Text(summary).font(.callout).padding(.top, 2)
            }
            if let longDescription = overview.longDescription {
                Text(longDescription).font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
            }
            Divider()
            ForEach(overview.metadataRows, id: \.label) { row in
                LabeledContent(row.label, value: row.value)
                    .font(.footnote)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ClassificationCard: View {
    let overview: DebOverview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(overview.verdict,
                  systemImage: overview.isConvertible
                    ? "checkmark.seal.fill" : "xmark.seal.fill")
                .foregroundStyle(overview.isConvertible ? .green : .red)
                .font(.callout)
            ForEach(overview.classificationRows, id: \.label) { row in
                if row.count > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(row.label) (\(row.count))")
                            .font(.footnote.weight(.semibold))
                        ForEach(row.items.prefix(5), id: \.self) { item in
                            Text(item).font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if row.items.count > 5 {
                            Text("+ \(row.items.count - 5) more…")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            ForEach(overview.reasons, id: \.self) { reason in
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct DependencyRowView: View {
    let row: DependencyRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.primary)
                .font(.callout.monospaced())
            if !row.alternatives.isEmpty {
                Text("alternatives: " + row.alternatives.joined(separator: " | "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
#endif
