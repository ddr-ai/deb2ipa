import Foundation

/// The M6 import pipeline outcome: every failure the parser stack can
/// produce is mapped to a typed, explained state here - the Import screen
/// renders `userMessage` and never sees a crash (SKILL.md M6 mandate).
public enum ImportOutcome: Equatable, Sendable {
    /// The deb parsed and classified successfully.
    case imported(DebPackage, DebClassification)
    /// The deb could not be imported; `failure.userMessage` explains why
    /// in one sentence a user can act on.
    case failed(ImportFailure)
}

/// One typed import failure with an actionable, user-facing explanation.
public struct ImportFailure: Error, Equatable, Sendable {
    /// The machine-readable failure class; `detail` carries the underlying
    /// parser message verbatim for diagnostics.
    public enum Kind: Equatable, Sendable {
        /// The file is empty or only a few bytes long.
        case emptyFile
        /// The file is larger than the import guard allows.
        case tooLarge
        /// The data does not begin with the ar magic - most likely not a
        /// .deb at all (an .ipa, a zip, a Mach-O binary...).
        case notADeb
        /// The ar container or one of its members is structurally broken.
        case corruptArchive
        /// The deb is missing the control.tar member or its control entry.
        case missingControl
        /// The control stanza exists but cannot be parsed.
        case corruptControl
    }

    public let kind: Kind
    public let detail: String
    public let filename: String?

    public init(kind: Kind, detail: String, filename: String? = nil) {
        self.kind = kind
        self.detail = detail
        self.filename = filename
    }

    /// One sentence explaining the failure and, where possible, what to do
    /// about it. This is the ONLY text the Import screen shows for errors.
    public var userMessage: String {
        let name = filename.map { "'\($0)'" } ?? "This file"
        switch kind {
        case .emptyFile:
            return "\(name) is empty - pick the actual .deb file."
        case .tooLarge:
            return "\(name) is larger than deb2ipa's import limit; use a deb URL instead of importing the file."
        case .notADeb:
            return "\(name) is not a Debian package - deb2ipa reads .deb archives, not IPAs, zips, or raw binaries."
        case .corruptArchive:
            return "\(name) looks like a deb but its archive structure is damaged (\(detail)). Re-download the package and try again."
        case .missingControl:
            return "\(name) has no readable control stanza (\(detail)); without it there is nothing to convert."
        case .corruptControl:
            return "\(name)'s control metadata could not be parsed (\(detail)). The package is likely malformed."
        }
    }
}

/// Parses and classifies a .deb from raw bytes, mapping every parser error
/// to a typed `ImportFailure`. This is the single entry point the Import
/// screen uses; it throws nothing and crashes on nothing.
public enum DebImporter {

    /// Import guard: local imports larger than this are rejected before
    /// parsing (the GitHub conversion path works from a URL instead).
    public static let maxImportBytes = 512 * 1024 * 1024

    /// Imports (parses + classifies) one deb.
    public static func importDeb(data: Data,
                                 filename: String? = nil,
                                 maxBytes: Int = DebImporter.maxImportBytes) -> ImportOutcome {
        let name = filename ?? "the file"
        guard !data.isEmpty else {
            return .failed(ImportFailure(kind: .emptyFile, detail: "0 bytes",
                                          filename: filename))
        }
        guard data.count <= maxBytes else {
            return .failed(ImportFailure(
                kind: .tooLarge,
                detail: "\(data.count) bytes > \(maxBytes) bytes limit",
                filename: filename))
        }
        do {
            let package = try DebPackage(debData: data)
            let classification = try package.classify()
            return .imported(package, classification)
        } catch let error as ArError {
            // ArError.notAnArArchive and .tooShort mean "not a deb" in the
            // common case; anything else is a damaged container.
            switch error {
            case .tooShort, .notAnArArchive:
                return .failed(ImportFailure(
                    kind: .notADeb, detail: error.description, filename: filename))
            case .malformedMemberHeader, .memberDataOutOfRange:
                return .failed(ImportFailure(
                    kind: .corruptArchive, detail: error.description, filename: filename))
            }
        } catch let error as DebError {
            switch error {
            case .missingDebianBinary, .unsupportedDebianVersion:
                // Structurally ar, but not a deb container.
                return .failed(ImportFailure(
                    kind: .notADeb, detail: error.description, filename: filename))
            case .missingControlMember, .unsupportedControlCompression,
                 .controlEntryMissing:
                return .failed(ImportFailure(
                    kind: .missingControl, detail: error.description, filename: filename))
            case .decompressionFailed:
                return .failed(ImportFailure(
                    kind: .corruptArchive, detail: error.description, filename: filename))
            }
        } catch let error as DebControlError {
            return .failed(ImportFailure(
                kind: .corruptControl, detail: error.description, filename: filename))
        } catch let error as DependencyParseError {
            // A malformed relationship field is a control problem, but the
            // rest of the stanza was fine: classify it as corrupt control
            // with the parser's own explanation.
            return .failed(ImportFailure(
                kind: .corruptControl, detail: error.localizedDescription, filename: filename))
        } catch {
            // Unknown error types still surface as a typed state - the
            // mandate is "never crash", not "never fail".
            return .failed(ImportFailure(
                kind: .corruptArchive, detail: String(describing: error), filename: filename))
        }
    }

    /// Reads a file URL into memory and imports it, mapping read errors to
    /// typed failures as well. `securityScoped` covers Files-app imports on
    /// iOS; the bookmark is released when done.
    public static func importDeb(from url: URL,
                                maxBytes: Int = DebImporter.maxImportBytes) -> ImportOutcome {
        // Security-scoped access only exists on Apple platforms; on Linux
        // (CI) this branch compiles out and the file reads plainly.
        #if canImport(UIKit) || canImport(AppKit)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        #endif
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .failed(ImportFailure(
                kind: .emptyFile,
                detail: "could not read file: \(error.localizedDescription)",
                filename: url.lastPathComponent))
        }
        return importDeb(data: data, filename: url.lastPathComponent,
                         maxBytes: maxBytes)
    }
}

/// A tiny debug helper used by screens when logging import paths.
extension ImportOutcome {
    /// True when the outcome is an importable, convertible package.
    public var isConvertible: Bool {
        switch self {
        case .imported(_, let classification):
            return classification.isConvertible
        case .failed:
            return false
        }
    }

    /// The imported package, when the import succeeded.
    public var package: DebPackage? {
        if case .imported(let package, _) = self { return package }
        return nil
    }

    /// The failure, when the import failed.
    public var failure: ImportFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }

    /// Stable description for logging (`name` is debug-only today).
    public var summary: String {
        switch self {
        case .imported(let package, let classification):
            return "imported \(package.control.package) \(package.control.version) "
                + "class=\(classification.class) convertible=\(classification.isConvertible)"
        case .failed(let failure):
            return "failed kind=\(failure.kind) detail=\(failure.detail)"
        }
    }
}
