import Foundation
import SWCompression

/// Extracts the control metadata from a deb archive.
public enum ControlExtractor {

    /// Decompresses a control or data tar member according to its compression.
    public static func decompress(_ memberData: Data, compression: TarCompression) throws -> Data {
        switch compression {
        case .none:
            return memberData
        case .gzip:
            do { return try GzipArchive.unarchive(archive: memberData) }
            catch { throw DebError.decompressionFailed("gzip: " + String(describing: error)) }
        case .xz:
            do { return try XZArchive.unarchive(archive: memberData) }
            catch { throw DebError.decompressionFailed("xz: " + String(describing: error)) }
        case .bzip2:
            do { return try BZip2.decompress(data: memberData) }
            catch { throw DebError.decompressionFailed("bzip2: " + String(describing: error)) }
        }
    }

    /// Opens a tar container with SWCompression.
    public static func entries(in tarData: Data) throws -> [TarEntry] {
        do { return try TarContainer.open(container: tarData) }
        catch { throw DebError.decompressionFailed("tar: " + String(describing: error)) }
    }

    /// Returns the raw bytes of the "control" stanza entry.
    ///
    /// dpkg names the entry "./control"; older or hand-made packages may use
    /// "control". Both are accepted.
    public static func controlData(from archive: DebArchive) throws -> Data {
        let tarData = try decompress(archive.controlTarData, compression: archive.controlCompression)
        let entries = try entries(in: tarData)

        guard let control = entries.first(where: { entry in
            let name = entry.info.name
            return name == "control" || name == "./control" || name.hasSuffix("/control")
        }), let data = control.data else {
            throw DebError.controlEntryMissing
        }
        return data
    }
}
