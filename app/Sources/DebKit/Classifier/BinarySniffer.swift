import Foundation

/// What a file's leading bytes reveal about the platform it was built for.
public struct BinaryInfo: Equatable, Sendable {
    /// Binary families the sniffer can tell apart.
    public enum Flavor: Equatable, Sendable {
        /// Thin 64-bit Mach-O with cputype arm64 (CPU_TYPE_ARM64).
        case machOArm64
        /// Fat / universal Mach-O containing at least one arm64 slice.
        case machOFatArm64
        /// Mach-O for some other architecture (x86_64, armv7, 32-bit arm...).
        case machOOther
        /// ELF object: Linux, BSD, and other desktop platforms.
        case elf
        /// Not a recognizable binary (or too small to be one).
        case unknown
    }

    /// The detected family.
    public let flavor: Flavor
    /// True when the image is a Mach-O MH_EXECUTE, i.e. a main executable.
    public let isExecutable: Bool
}

/// Identifies binaries from their magic numbers, without any OS frameworks:
/// Mach-O (thin and fat) and ELF detection need at most the first 68 bytes.
public enum BinarySniffer {

    private static let cpuTypeArm64: UInt32 = 0x0100_000C
    private static let mhMagic64: UInt32 = 0xFEED_FACF
    private static let mhFileTypeExecute: UInt32 = 2

    /// Sniffs the beginning of a file. Extra bytes beyond what the headers
    /// need are ignored, so a file prefix is a valid input.
    public static func sniff(_ data: Data) -> BinaryInfo {
        // Copy to a plain array: Data slices keep their original indices,
        // and integer indexing keeps the header parsing below obvious.
        let head = [UInt8](data.prefix(68))
        guard head.count >= 4 else {
            return BinaryInfo(flavor: .unknown, isExecutable: false)
        }

        // ELF: 0x7F 'E' 'L' 'F'
        if head[0] == 0x7F, head[1] == 0x45, head[2] == 0x4C, head[3] == 0x46 {
            return BinaryInfo(flavor: .elf, isExecutable: false)
        }

        // Fat / universal Mach-O. Apple tools write the fat header fields
        // big-endian, and so do the debs built for jailbroken devices.
        if head[0] == 0xCA, head[1] == 0xFE, head[2] == 0xBA, head[3] == 0xBE {
            return sniffFat(head)
        }

        // Thin 64-bit Mach-O, little-endian: magic bytes CF FA ED FE.
        if head[0] == 0xCF, head[1] == 0xFA, head[2] == 0xED, head[3] == 0xFE {
            guard head.count >= 16, let cputype = le32(head, 4) else {
                return BinaryInfo(flavor: .machOOther, isExecutable: false)
            }
            let fileType = le32(head, 12) ?? 0
            if cputype == cpuTypeArm64 {
                return BinaryInfo(flavor: .machOArm64, isExecutable: fileType == mhFileTypeExecute)
            }
            return BinaryInfo(flavor: .machOOther, isExecutable: false)
        }

        // Thin 32-bit Mach-O (armv7 era): magic bytes FE ED FA CE.
        if head[0] == 0xFE, head[1] == 0xED, head[2] == 0xFA, head[3] == 0xCE {
            return BinaryInfo(flavor: .machOOther, isExecutable: false)
        }

        return BinaryInfo(flavor: .unknown, isExecutable: false)
    }

    /// Reads a fat container's architecture list looking for an arm64 slice.
    private static func sniffFat(_ head: [UInt8]) -> BinaryInfo {
        guard let nfatArch = be32(head, 4) else {
            return BinaryInfo(flavor: .machOOther, isExecutable: false)
        }
        var hasArm64 = false
        var arm64SliceIsExecute = false
        // Trust nobody: a corrupted header can claim absurd counts.
        let archCount = min(nfatArch, 64)
        for i in 0..<archCount {
            let archBase = 8 + 20 * i
            guard let cputype = be32(head, archBase) else { break }
            guard cputype == cpuTypeArm64 else { continue }
            hasArm64 = true
            // fat_arch layout: cputype, cpusubtype, offset, size, align. The
            // slice itself starts at `offset`; read its Mach-O header to
            // learn whether this arm64 slice is a main executable.
            if let offset = be32(head, archBase + 8) {
                let slice = Int(offset)
                if let magic = le32(head, slice), magic == mhMagic64,
                   let fileType = le32(head, slice + 12),
                   fileType == mhFileTypeExecute {
                    arm64SliceIsExecute = true
                }
            }
        }
        return BinaryInfo(
            flavor: hasArm64 ? .machOFatArm64 : .machOOther,
            isExecutable: arm64SliceIsExecute)
    }

    /// 32-bit little-endian read with bounds checking.
    private static func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32? {
        guard offset >= 0, bytes.count >= offset + 4 else { return nil }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    /// 32-bit big-endian read with bounds checking.
    private static func be32(_ bytes: [UInt8], _ offset: Int) -> UInt32? {
        guard offset >= 0, bytes.count >= offset + 4 else { return nil }
        return (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }
}
