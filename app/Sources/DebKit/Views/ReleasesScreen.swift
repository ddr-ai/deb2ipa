#if canImport(SwiftUI)
import SwiftUI

/// Releases screen: the conversion repository's releases, with IPA
/// handoff to AltStore (custom scheme) or the share sheet (primary).
public struct ReleasesScreen: View {
    @ObservedObject var environment: AppEnvironment
    @ObservedObject var store: ReleasesStore

    @Environment(\.openURL) private var openURL

    public var body: some View {
        NavigationStack {
            List {
                if let error = store.loadError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                ForEach(store.releases, id: \.id) { release in
                    ReleaseRow(release: release,
                               preferences: environment.preferences,
                               openURL: openExternal)
                }
            }
            .refreshable { await store.refresh(environment: environment) }
            .navigationTitle("Releases")
            .task { await store.refresh(environment: environment) }
        }
    }

    private func openExternal(_ url: URL) {
        openURL(url)
    }
}

private struct ReleaseRow: View {
    let release: GitHubRelease
    let preferences: AppPreferences
    var openURL: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(release.name ?? release.tagName)
                    .font(.headline)
                if release.draft == true {
                    Text("DRAFT")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange.opacity(0.2), in: Capsule())
                }
                Spacer()
                Text(release.tagName).font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            ForEach(release.assets, id: \.id) { asset in
                AssetRow(asset: asset,
                         isIPA: Sideload.isIPAAsset(named: asset.name),
                         preferences: preferences,
                         openURL: openURL)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct AssetRow: View {
    let asset: GitHubReleaseAsset
    let isIPA: Bool
    let preferences: AppPreferences
    var openURL: (URL) -> Void

    var body: some View {
        HStack {
            Image(systemName: isIPA ? "app.badge.fill" : "doc")
                .foregroundStyle(isIPA ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading) {
                Text(asset.name).font(.callout.monospaced())
                Text(ByteCountFormatter.string(fromByteCount: asset.size,
                                               countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isIPA, let url = browserURL {
                handoffButtons(url: url)
            }
        }
    }

    private var browserURL: URL? {
        guard let string = asset.browserDownloadURL else { return nil }
        return URL(string: string)
    }

    @ViewBuilder
    private func handoffButtons(url: URL) -> some View {
        switch preferences.installTarget {
        case .altStore:
            Button("Install") { handoff(url) }
                .buttonStyle(.borderedProminent)
        case .shareSheet, .ask:
            ShareLink("Share", item: url)
            Menu {
                Button("Install with AltStore") { handoff(url) }
                ShareLink("Share…", item: url)
            } label: {
                Label("Install", systemImage: "arrow.down.app")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func handoff(_ ipaURL: URL) {
        if let handoff = Sideload.handoff(ipaURL: ipaURL, target: preferences.installTarget),
           case .altStoreInstall(let install) = handoff {
            openURL(install)
        }
    }
}
#endif
