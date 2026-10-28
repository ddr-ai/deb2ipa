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

/// Identifies binaries from their magic numbers, without any OS frameworks.
/// Thin Mach-O and ELF detection need at most the first 68 bytes, but fat
/// containers are followed wherever their fat_arch offsets point: real fat
/// binaries (lipo, Apple tools) place the first slice at 4 KiB or beyond,
/// far past any fixed prefix (see SKILL.md lesson 7.M).
public enum BinarySniffer {

    private static let cpuTypeArm64: UInt32 = 0x0100_000C
    private static let mhMagic64: UInt32 = 0xFEED_FACF
    private static let mhFileTypeExecute: UInt32 = 2

    /// Sniffs a file prefix or a whole file; every read is bounds-checked.
    public static func sniff(_ data: Data) -> BinaryInfo {
        guard data.count >= 4 else {
            return BinaryInfo(flavor: .unknown, isExecutable: false)
        }
        let b0 = data[data.startIndex]
        let b1 = data[data.startIndex + 1]
        let b2 = data[data.startIndex + 2]
        let b3 = data[data.startIndex + 3]

        // ELF: 0x7F 'E' 'L' 'F'
        if b0 == 0x7F, b1 == 0x45, b2 == 0x4C, b3 == 0x46 {
            return BinaryInfo(flavor: .elf, isExecutable: false)
        }

        // Fat / universal Mach-O. Apple tools write the fat header fields
        // big-endian, and so do the debs built for jailbroken devices.
        if b0 == 0xCA, b1 == 0xFE, b2 == 0xBA, b3 == 0xBE {
            return sniffFat(data)
        }

        // Thin 64-bit Mach-O, little-endian: magic bytes CF FA ED FE.
        if b0 == 0xCF, b1 == 0xFA, b2 == 0xED, b3 == 0xFE {
            guard data.count >= 16, let cputype = le32(data, 4) else {
                return BinaryInfo(flavor: .machOOther, isExecutable: false)
            }
            let fileType = le32(data, 12) ?? 0
            if cputype == cpuTypeArm64 {
                return BinaryInfo(flavor: .machOArm64, isExecutable: fileType == mhFileTypeExecute)
            }
            return BinaryInfo(flavor: .machOOther, isExecutable: false)
        }

        // Thin 32-bit Mach-O (armv7 era): magic bytes FE ED FA CE.
        if b0 == 0xFE, b1 == 0xED, b2 == 0xFA, b3 == 0xCE {
            return BinaryInfo(flavor: .machOOther, isExecutable: false)
        }

        return BinaryInfo(flavor: .unknown, isExecutable: false)
    }

    /// Reads a fat container's architecture list looking for an arm64
    /// slice. The slice header is read at the fat_arch offset inside the
    /// FULL file - the offset routinely sits thousands of bytes in.
    private static func sniffFat(_ data: Data) -> BinaryInfo {
        guard let nfatArch = be32(data, 4) else {
            return BinaryInfo(flavor: .machOOther, isExecutable: false)
        }
        var hasArm64 = false
        var arm64SliceIsExecute = false
        // Trust nobody: a corrupted header can claim absurd counts.
        let archCount = min(nfatArch, 64)
        for i in 0..<archCount {
            let archBase = 8 + 20 * i
            guard let cputype = be32(data, archBase) else { break }
            guard cputype == cpuTypeArm64 else { continue }
            hasArm64 = true
            // fat_arch layout: cputype, cpusubtype, offset, size, align. The
            // slice itself starts at `offset`; read its Mach-O header to
            // learn whether this arm64 slice is a main executable. Bounds
            // checks in le32 make a truncated/corrupt offset safe.
            if let offset = be32(data, archBase + 8) {
                let slice = Int(offset)
                if le32(data, slice) == mhMagic64,
                   le32(data, slice + 12) == mhFileTypeExecute {
                    arm64SliceIsExecute = true
                }
            }
        }
        return BinaryInfo(
            flavor: hasArm64 ? .machOFatArm64 : .machOOther,
            isExecutable: arm64SliceIsExecute)
    }

    /// 32-bit little-endian read with bounds checking.
    private static func le32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let i = data.startIndex + offset
        return UInt32(data[i])
            | (UInt32(data[i + 1]) << 8)
            | (UInt32(data[i + 2]) << 16)
            | (UInt32(data[i + 3]) << 24)
    }

    /// 32-bit big-endian read with bounds checking.
    private static func be32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let i = data.startIndex + offset
        return (UInt32(data[i]) << 24)
            | (UInt32(data[i + 1]) << 16)
            | (UInt32(data[i + 2]) << 8)
            | UInt32(data[i + 3])
    }
}
