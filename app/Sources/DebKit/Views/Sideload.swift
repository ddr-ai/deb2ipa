import Foundation

/// What deb2ipa does with a finished IPA. The share sheet is the primary
/// handoff (any sideload tool works); AltStore's install scheme is the
/// one-tap path when AltStore is installed.
public enum InstallTarget: String, CaseIterable, Codable, Sendable {
    /// Always hand off via `altstore://install?url=...`.
    case altStore
    /// Always open the iOS share sheet with the IPA URL/file.
    case shareSheet
    /// Ask each time (default).
    case ask

    public var label: String {
        switch self {
        case .altStore: return "AltStore (one-tap install)"
        case .shareSheet: return "Share sheet"
        case .ask: return "Ask every time"
        }
    }
}

/// One concrete handoff action the UI should perform.
public enum SideloadHandoff: Equatable, Sendable {
    /// Open `altstore://install?url=<encoded ipa url>`; AltStore downloads
    /// and installs the IPA itself.
    case altStoreInstall(url: URL)
    /// Present the share sheet with an IPA URL (remote) or file (local).
    case shareSheet(url: URL)

    public var debugDescription: String {
        switch self {
        case .altStoreInstall(let url): return "altstore \(url)"
        case .shareSheet(let url): return "share \(url)"
        }
    }
}

/// AltStore / share-sheet handoff construction. Pure URL logic so it is
/// unit-testable on Linux.
public enum Sideload {

    /// AltStore's custom scheme: `altstore://install?url=<percent-encoded
    /// https url>`. Returns nil when the source URL cannot be encoded.
    public static func altStoreInstallURL(for ipaURL: URL) -> URL? {
        // Only public http(s) URLs can work: AltStore fetches the IPA
        // itself, it cannot reach a local file.
        guard let scheme = ipaURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let encoded = ipaURL.absoluteString.addingPercentEncoding(
                  withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: "altstore://install?url=" + encoded)
    }

    /// The handoff for a release asset, honoring the user's install
    /// target preference. `.ask` callers should present the choice UI
    /// themselves; this maps it to the share sheet as the safe default.
    public static func handoff(ipaURL: URL,
                               target: InstallTarget) -> SideloadHandoff? {
        switch target {
        case .altStore:
            guard let install = altStoreInstallURL(for: ipaURL) else { return nil }
            return .altStoreInstall(url: install)
        case .shareSheet, .ask:
            return .shareSheet(url: ipaURL)
        }
    }

    /// True when the release asset looks like an IPA by name.
    public static func isIPAAsset(named name: String) -> Bool {
        name.lowercased().hasSuffix(".ipa")
    }
}
