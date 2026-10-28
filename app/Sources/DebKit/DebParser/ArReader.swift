import Foundation

/// Errors encountered while reading the ar container of a Debian package.
public enum ArError: Error, Equatable {
    /// Fewer bytes than the fixed 8-byte ar magic.
    case tooShort
    /// The data does not begin with the ar magic string.
    case notAnArArchive
    /// A member header was truncated or malformed.
    case malformedMemberHeader
    /// The size advertised in a member header runs past the end of the file.
    case memberDataOutOfRange(name: String, size: Int)
}

extension ArError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .tooShort:
            return "Not enough data for an ar archive."
        case .notAnArArchive:
            return "The file does not start with the ar magic."
        case .malformedMemberHeader:
            return "A member header is truncated or malformed."
        case .memberDataOutOfRange(let name, let size):
            return "Member '" + name + "' claims " + String(size)
                + " bytes, which run past the end of the file."
        }
    }
}

/// One member (file) inside an ar archive.
public struct ArMember: Equatable, Sendable {
    /// The member file name, with BSD-style extended names resolved.
    public let name: String
    /// The member raw payload.
    public let data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

/// Reads the classic Unix ar archive that wraps every Debian package.
///
/// A .deb file is an ar archive containing exactly three members:
///   1. "debian-binary" - the literal string "2.0"
///   2. "control.tar" plus a compression suffix - the control metadata
///   3. "data.tar" plus a compression suffix - the payload file tree
///
/// Layout reference (man 5 ar): a global 8-byte magic, then, per member, a
/// 60-byte ASCII header: name[16] date[12] uid[6] gid[6] mode[8] size[10]
/// followed by the two-character footer. Member data is padded to an even
/// number of bytes with a newline.
public struct ArReader: Sendable {

    /// The ar global magic: exclamation mark, "arch", newline. 8 bytes.
    private static let magic: [UInt8] = Array("!<arch>\n".utf8)

    /// Every member header occupies exactly 60 bytes.
    private static let headerSize = 60

    private let data: Data

    /// Creates a reader over the raw bytes of a Debian package file.
    public init(data: Data) {
        self.data = data
    }

    /// Returns every member of the archive, in archive order.
    public func members() throws -> [ArMember] {
        guard data.count >= 8 else { throw ArError.tooShort }

        let base = data.startIndex
        guard Array(data[base ..< base + 8]) == ArReader.magic else {
            throw ArError.notAnArArchive
        }

        var members: [ArMember] = []
        var offset = 8

        while offset < data.count {
            // A lone trailing byte is padding from the previous member.
            guard offset + ArReader.headerSize <= data.count else {
                throw ArError.malformedMemberHeader
            }

            let headerStart = base + offset

            // The 60-byte header must end with the two-byte footer
            // (backtick + newline).
            guard data[headerStart + 58] == 0x60, data[headerStart + 59] == 0x0A else {
                throw ArError.malformedMemberHeader
            }

            let nameField = String(decoding: data[headerStart ..< headerStart + 16], as: UTF8.self)
            let sizeField = String(decoding: data[headerStart + 48 ..< headerStart + 58], as: UTF8.self)

            guard let size = Int(sizeField.trimmingCharacters(in: .whitespacesAndNewlines)),
                  size >= 0 else {
                throw ArError.malformedMemberHeader
            }

            let start = headerStart + ArReader.headerSize
            let end = start + size
            guard end <= data.endIndex else {
                throw ArError.memberDataOutOfRange(
                    name: Self.cleaned(nameField), size: size)
            }

            let memberData = Data(data[start ..< end])
            members.append(ArMember(
                name: Self.resolvedName(nameField: nameField, memberData: memberData),
                data: memberData))

            // Advance past the member, plus one padding byte when its size
            // was odd.
            offset += ArReader.headerSize + size
            if size % 2 == 1 { offset += 1 }
        }

        return members
    }

    /// Strips padding whitespace and any trailing slash from a header name.
    private static func cleaned(_ nameField: String) -> String {
        nameField.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n/"))
    }

    /// Resolves BSD-style extended names: a header name of the form "#1/23"
    /// means the first 23 bytes of the member data are the real file name.
    private static func resolvedName(nameField: String, memberData: Data) -> String {
        let name = cleaned(nameField)
        if name.hasPrefix("#1/"), let length = Int(name.dropFirst(3)), length <= memberData.count {
            return String(decoding: memberData.prefix(length), as: UTF8.self)
        }
        return name
    }
}
