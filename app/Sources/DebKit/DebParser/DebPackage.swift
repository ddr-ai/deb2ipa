import Foundation

/// A fully parsed Debian package: archive structure plus control metadata.
///
/// This is the single entry point the app uses on-device:
///     let package = try DebPackage(debData: data)
///     package.control.depends
public struct DebPackage: Equatable, Sendable {
    /// The parsed control stanza.
    public let control: DebControl

    /// Parses a deb from raw bytes: ar container, control tar member,
    /// decompression, and the control stanza.
    public init(debData: Data) throws {
        let archive = try DebArchive(debData: debData)
        let controlData = try ControlExtractor.controlData(from: archive)
        self.control = try DebControlParser.parse(controlData)
    }
}
