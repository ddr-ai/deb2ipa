import XCTest
@testable import DebKit

final class ClassifierTests: XCTestCase {

    // MARK: - Full-package classification via the DebPackage facade

    private func classified(_ data: Data) throws -> DebClassification {
        try DebPackage(debData: data).classify()
    }

    func testStandardAppDebIsConvertibleApp() throws {
        let c = try classified(ClassifierFixtures.appStandard)
        XCTAssertEqual(c.class, .app)
        XCTAssertTrue(c.isConvertible)
        XCTAssertEqual(c.appBundlePaths, ["Applications/Hello.app"])
        XCTAssertEqual(c.arm64Executables, ["Applications/Hello.app/Hello"])
    }

    func testAppInNonstandardLocationIsConvertible() throws {
        // The .app is not under Applications/ at all - the classifier must
        // find it wherever it hides.
        let c = try classified(ClassifierFixtures.appNonstandard)
        XCTAssertEqual(c.class, .app)
        XCTAssertTrue(c.isConvertible)
        XCTAssertEqual(c.appBundlePaths, ["Library/Custom/Spot.app"])
        XCTAssertEqual(c.arm64Executables, ["Library/Custom/Spot.app/Spot"])
    }

    func testRootlessAppIsConvertible() throws {
        let c = try classified(ClassifierFixtures.appRootless)
        XCTAssertEqual(c.class, .app)
        XCTAssertTrue(c.isConvertible)
        XCTAssertEqual(c.appBundlePaths, ["var/jb/Applications/RL.app"])
    }

    func testFatBinaryAppIsConvertible() throws {
        // Legacy rootful deb (iphoneos-arm) whose executable is a fat
        // binary containing an arm64 slice: still convertible.
        let c = try classified(ClassifierFixtures.appFat)
        XCTAssertEqual(c.class, .app)
        XCTAssertTrue(c.isConvertible)
        XCTAssertEqual(c.arm64Executables, ["Applications/Fat.app/Fat"])
    }

    func testTweakDebIsRejectedWithExplanation() throws {
        let c = try classified(ClassifierFixtures.tweak)
        XCTAssertEqual(c.class, .tweak)
        XCTAssertFalse(c.isConvertible)
        XCTAssertEqual(c.substrateDylibs, ["Library/MobileSubstrate/DynamicLibraries/exampletweak.dylib"])
        XCTAssertTrue(c.reasons.contains { $0.contains("MobileSubstrate") })
    }

    func testThemePackIsNotConvertible() throws {
        let c = try classified(ClassifierFixtures.theme)
        XCTAssertEqual(c.class, .themePack)
        XCTAssertFalse(c.isConvertible)
        XCTAssertTrue(c.appBundlePaths.isEmpty)
    }

    func testLinuxDebIsNonIOS() throws {
        let c = try classified(ClassifierFixtures.nonIOS)
        XCTAssertEqual(c.class, .nonIOS)
        XCTAssertFalse(c.isConvertible)
        XCTAssertEqual(c.elfBinaries, ["usr/bin/linuxtool"])
    }

    func testAppBundleWithoutArm64ExecutableIsNotConvertible() throws {
        // "Actually runs" is the bar: a bundle with no native executable
        // classifies as an app but stays unconvertible, with the reason.
        let c = try classified(ClassifierFixtures.appNoBinary)
        XCTAssertEqual(c.class, .app)
        XCTAssertFalse(c.isConvertible)
        XCTAssertEqual(c.appBundlePaths, ["Applications/Web.app"])
        XCTAssertTrue(c.reasons.contains { $0.contains("No arm64 Mach-O executable") })
    }

    func testControlArchitectureIsAdvisoryNotTheGate() throws {
        // Content decides: an "all" package with an arm64 .app converts,
        // and an "iphoneos-arm" fat-binary package converts too.
        let noBinaryPkg = try DebPackage(debData: ClassifierFixtures.appNoBinary)
        XCTAssertEqual(noBinaryPkg.control.architecture, "all")
        XCTAssertFalse(try noBinaryPkg.classify().isConvertible)

        let fatPkg = try DebPackage(debData: ClassifierFixtures.appFat)
        XCTAssertEqual(fatPkg.control.architecture, "iphoneos-arm")
        XCTAssertTrue(try fatPkg.classify().isConvertible)
    }

    // MARK: - BinarySniffer

    private func macho64(cputype: UInt32 = 0x0100000C, fileType: UInt32 = 2) -> Data {
        var data = Data()
        func appendLE32(_ value: UInt32) {
            data.append(UInt8(value & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8((value >> 16) & 0xFF))
            data.append(UInt8((value >> 24) & 0xFF))
        }
        appendLE32(0xFEED_FACF) // MH_MAGIC_64
        appendLE32(cputype)     // cputype
        appendLE32(0)           // cpusubtype
        appendLE32(fileType)    // filetype
        appendLE32(0); appendLE32(0); appendLE32(0); appendLE32(0)
        return data
    }

    func testSnifferDetectsThinArm64Execute() {
        let info = BinarySniffer.sniff(macho64())
        XCTAssertEqual(info.flavor, .machOArm64)
        XCTAssertTrue(info.isExecutable)
    }

    func testSnifferDetectsArm64Dylib() {
        let info = BinarySniffer.sniff(macho64(fileType: 6))
        XCTAssertEqual(info.flavor, .machOArm64)
        XCTAssertFalse(info.isExecutable)
    }

    func testSnifferDetectsX86_64MachOAsOther() {
        let info = BinarySniffer.sniff(macho64(cputype: 0x01000007))
        XCTAssertEqual(info.flavor, .machOOther)
    }

    func testSnifferDetectsFatArm64Execute() {
        var fat = Data()
        func appendBE32(_ value: UInt32) {
            fat.append(UInt8((value >> 24) & 0xFF))
            fat.append(UInt8((value >> 16) & 0xFF))
            fat.append(UInt8((value >> 8) & 0xFF))
            fat.append(UInt8(value & 0xFF))
        }
        appendBE32(0xCAFEBABE) // fat magic
        appendBE32(1)          // nfat_arch
        appendBE32(0x0100000C) // cputype arm64
        appendBE32(0)          // cpusubtype
        appendBE32(32)         // offset
        appendBE32(32)         // size
        appendBE32(14)         // align
        fat.append(Data(repeating: 0, count: 8)) // pad to offset 32
        fat.append(macho64(cputype: 0x0100000C, fileType: 2))
        let info = BinarySniffer.sniff(fat)
        XCTAssertEqual(info.flavor, .machOFatArm64)
        XCTAssertTrue(info.isExecutable)
    }

    func testSnifferDetectsELF() {
        let elf = Data([0x7F, 0x45, 0x4C, 0x46, 0x02, 0x01, 0x01, 0x00])
        XCTAssertEqual(BinarySniffer.sniff(elf).flavor, .elf)
    }

    func testSnifferRejectsPlainTextAndShortData() {
        XCTAssertEqual(BinarySniffer.sniff(Data("hello, world".utf8)).flavor, .unknown)
        XCTAssertEqual(BinarySniffer.sniff(Data([0xCF, 0xFA])).flavor, .unknown)
    }
}
