import Foundation

/// One label/value line of the Import screen's metadata card.
public struct MetadataRow: Equatable, Sendable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// One evidence line of the classification card.
public struct ClassificationRow: Equatable, Sendable {
    public let label: String
    public let count: Int
    public let items: [String]

    public init(label: String, count: Int, items: [String]) {
        self.label = label
        self.count = count
        self.items = items
    }
}

/// Pure display model for the Import screen: everything the metadata card
/// and the classification verdict render, derived from the parsed control
/// stanza and the classifier's evidence. No SwiftUI dependency, so it is
/// fully unit-testable on the Linux CI.
public struct DebOverview: Equatable, Sendable {

    // MARK: - Control metadata

    /// Display title: the human `Name` field when present, else the package id.
    public let title: String
    /// The Debian package identifier (e.g. ws.hbang.newterm3).
    public let packageID: String
    public let version: String
    public let architecture: String
    public let maintainer: String?
    public let section: String?
    public let priority: String?
    /// Installed-Size (KB in Debian control) converted to bytes.
    public let installedSizeBytes: Int?
    /// The size of the .deb file itself.
    public let debSizeBytes: Int
    public let summary: String?
    public let longDescription: String?
    public let homepage: String?

    // MARK: - Classification verdict

    /// The classifier's payload class.
    public let `class`: DebClass
    /// True when an IPA built from this deb will actually launch.
    public let isConvertible: Bool
    /// One-sentence verdict for the big status banner.
    public let verdict: String
    /// The classifier's evidence lines, display-ordered.
    public let reasons: [String]
    public let appBundlePaths: [String]
    public let arm64Executables: [String]
    public let elfBinaries: [String]
    public let substrateDylibs: [String]

    public init(control: DebControl,
                classification: DebClassification,
                debSizeBytes: Int) {
        self.title = control.name?.isEmpty == false ? control.name! : control.package
        self.packageID = control.package
        self.version = control.version
        self.architecture = control.architecture ?? "unknown"
        self.maintainer = control.maintainer
        self.section = control.section
        self.priority = control.priority
        self.installedSizeBytes = control.installedSize.map { $0 * 1024 }
        self.debSizeBytes = debSizeBytes
        self.summary = control.summary
        self.longDescription = control.longDescription
        self.homepage = control.homepage
        self.class = classification.class
        self.isConvertible = classification.isConvertible
        self.verdict = Self.verdictSentence(classification)
        self.reasons = classification.reasons
        self.appBundlePaths = classification.appBundlePaths
        self.arm64Executables = classification.arm64Executables
        self.elfBinaries = classification.elfBinaries
        self.substrateDylibs = classification.substrateDylibs
    }

    /// The big banner sentence. Positive when convertible; otherwise the
    /// first classifier reason explains what went wrong, so the user sees
    /// an explanation rather than a bare "no".
    private static func verdictSentence(_ classification: DebClassification) -> String {
        if classification.isConvertible {
            switch classification.class {
            case .app:
                return "Convertible - this package carries a .app bundle with an arm64 executable."
            case .tweak, .iosTools, .nonIOS, .themePack:
                // isConvertible only flips true for the .app class today,
                // but stay honest if that ever changes.
                return "Convertible to an installable IPA."
            }
        }
        switch classification.class {
        case .tweak:
            return "Not convertible on its own - this is a MobileSubstrate tweak that injects into other apps."
        case .iosTools:
            return "Not convertible - these are iOS command-line tools with no .app bundle to launch from."
        case .nonIOS:
            return "Not convertible - the binaries inside are built for Linux or desktop platforms."
        case .themePack:
            return "Not convertible - this package only carries themes or data files, no executable."
        case .app:
            return "Not convertible - a .app bundle is present but no arm64 main executable was found inside."
        }
    }

    /// "1.2 KB" / "3.4 MB" style formatting, 1 significant decimal.
    public static func formattedByteCount(_ bytes: Int) -> String {
        guard bytes > 0 else { return "0 KB" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.1f GB", mb / 1024)
    }

    /// Rows for the "Package" table on the Import screen: label + value,
    /// hidden when the value is missing.
    public var metadataRows: [MetadataRow] {
        var rows: [MetadataRow] = [
            MetadataRow(label: "Package", value: packageID),
            MetadataRow(label: "Version", value: version),
            MetadataRow(label: "Architecture", value: architecture),
        ]
        if let section { rows.append(MetadataRow(label: "Section", value: section)) }
        if let priority { rows.append(MetadataRow(label: "Priority", value: priority)) }
        if let maintainer { rows.append(MetadataRow(label: "Maintainer", value: maintainer)) }
        if let installedSizeBytes {
            rows.append(MetadataRow(label: "Installed size",
                                    value: Self.formattedByteCount(installedSizeBytes)))
        }
        if debSizeBytes > 0 {
            rows.append(MetadataRow(label: "Deb size",
                                    value: Self.formattedByteCount(debSizeBytes)))
        }
        return rows
    }

    /// Rows for the classification evidence card.
    public var classificationRows: [ClassificationRow] {
        [
            ClassificationRow(label: "App bundles", count: appBundlePaths.count,
                              items: appBundlePaths),
            ClassificationRow(label: "arm64 executables", count: arm64Executables.count,
                              items: arm64Executables),
            ClassificationRow(label: "ELF binaries", count: elfBinaries.count,
                              items: elfBinaries),
            ClassificationRow(label: "MobileSubstrate dylibs", count: substrateDylibs.count,
                              items: substrateDylibs),
        ].filter { $0.count > 0 || $0.items.isEmpty && $0.label == "App bundles" }
    }
}
