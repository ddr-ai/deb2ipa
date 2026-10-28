import Foundation

/// The compression applied to a tar member inside a deb.
public enum TarCompression: Equatable, Sendable {
    case none
    case gzip
    case xz
    case bzip2

    /// Maps a member name such as "control.tar.xz" to its compression kind.
    /// Returns nil for compressions the parser cannot read (lzma, zstd).
    public static func from(memberName: String) -> TarCompression? {
        switch memberName {
        case "control.tar", "data.tar":
            return .none
        case "control.tar.gz", "data.tar.gz":
            return .gzip
        case "control.tar.xz", "data.tar.xz":
            return .xz
        case "control.tar.bz2", "data.tar.bz2":
            return .bzip2
        default:
            return nil
        }
    }
}

/// Errors thrown while interpreting the structure of a deb.
public enum DebError: Error, Equatable {
    /// The archive has no "debian-binary" member.
    case missingDebianBinary
    /// The debian-binary member did not say "2.0".
    case unsupportedDebianVersion(String)
    /// There is no control.tar member at all.
    case missingControlMember
    /// The control member uses a compression this parser cannot read.
    case unsupportedControlCompression(String)
    /// A tar member could not be decompressed or opened.
    case decompressionFailed(String)
    /// The control tar does not contain a "control" entry.
    case controlEntryMissing
}

extension DebError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .missingDebianBinary:
            return "The archive is missing its debian-binary member."
        case .unsupportedDebianVersion(let v):
            return "Unsupported deb format version: " + v
        case .missingControlMember:
            return "The archive is missing its control.tar member."
        case .unsupportedControlCompression(let name):
            return "Unsupported control compression: " + name
        case .decompressionFailed(let detail):
            return "Failed to decompress a tar member: " + detail
        case .controlEntryMissing:
            return "The control tar has no control stanza."
        }
    }
}

/// A parsed deb archive: the three ar members of a Debian package.
public struct DebArchive: Sendable {
    /// Compression of the control member.
    public let controlCompression: TarCompression
    /// Raw bytes of the control tar member (still compressed).
    public let controlTarData: Data
    /// Compression of the data member, nil when absent or unsupported.
    public let dataCompression: TarCompression?
    /// Raw bytes of the data tar member (still compressed), if available.
    public let dataTarData: Data?

    /// Validates the ar structure, the debian-binary version, and locates the
    /// control and data members.
    public init(debData: Data) throws {
        let members = try ArReader(data: debData).members()

        guard let binary = members.first(where: { $0.name == "debian-binary" }) else {
            throw DebError.missingDebianBinary
        }
        let formatVersion = String(decoding: binary.data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard formatVersion == "2.0" else {
            throw DebError.unsupportedDebianVersion(formatVersion)
        }

        guard let control = members.first(where: { $0.name.hasPrefix("control.tar") }) else {
            throw DebError.missingControlMember
        }
        guard let compression = TarCompression.from(memberName: control.name) else {
            throw DebError.unsupportedControlCompression(control.name)
        }
        controlCompression = compression
        controlTarData = control.data

        if let data = members.first(where: { $0.name.hasPrefix("data.tar") }),
           let dataCompression = TarCompression.from(memberName: data.name) {
            self.dataCompression = dataCompression
            dataTarData = data.data
        } else {
            self.dataCompression = nil
            dataTarData = nil
        }
    }
}
