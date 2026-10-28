import XCTest
import DebKit

final class DebArchiveTests: XCTestCase {

    // MARK: Real dpkg-built fixtures

    func testArMemberNamesOfRealDeb() throws {
        let members = try ArReader(data: Fixtures.debXZ).members()
        XCTAssertEqual(members.map(\.name),
                       ["debian-binary", "control.tar.xz", "data.tar.xz"])
        XCTAssertEqual(members[0].data, Data("2.0\n".utf8))
    }

    func testXZControlExtraction() throws {
        let archive = try DebArchive(debData: Fixtures.debXZ)
        XCTAssertEqual(archive.controlCompression, .xz)
        XCTAssertEqual(archive.dataCompression, .xz)
        let control = try DebControlParser.parse(try ControlExtractor.controlData(from: archive))
        XCTAssertEqual(control.package, "ws.hbang.newterm3")
    }

    func testGzipControlExtraction() throws {
        let archive = try DebArchive(debData: Fixtures.debGZ)
        XCTAssertEqual(archive.controlCompression, .gzip)
        let control = try DebControlParser.parse(try ControlExtractor.controlData(from: archive))
        XCTAssertEqual(control.version, "3.0~beta1-18")
        XCTAssertEqual(control.architecture, "iphoneos-arm64")
    }

    func testUncompressedControlExtraction() throws {
        // Decompress the gz member with SWCompression itself, then rewrap
        // the plain control.tar in a hand-made ar archive (compression none).
        let gzArchive = try DebArchive(debData: Fixtures.debGZ)
        let plainControl = try ControlExtractor.decompress(
            gzArchive.controlTarData, compression: .gzip)
        let deb = Fixtures.ar([
            ("debian-binary", Data("2.0\n".utf8)),
            ("control.tar", plainControl),
        ])
        let archive = try DebArchive(debData: deb)
        XCTAssertEqual(archive.controlCompression, .none)
        XCTAssertNil(archive.dataTarData)
        let control = try DebControlParser.parse(try ControlExtractor.controlData(from: archive))
        XCTAssertEqual(control.name, "NewTerm 3")
    }

    func testFullPackageParsing() throws {
        let pkg = try DebPackage(debData: Fixtures.debXZ)
        XCTAssertEqual(pkg.control.package, "ws.hbang.newterm3")
        XCTAssertEqual(pkg.control.name, "NewTerm 3")
        XCTAssertEqual(pkg.control.architecture, "iphoneos-arm64")
        XCTAssertEqual(pkg.control.depends?.groups.count, 3)
        XCTAssertEqual(pkg.control.summary, "A terminal emulator for iOS")
    }

    func testOddMemberPadding() throws {
        let data = Fixtures.ar([("odd", Data([0x01, 0x02, 0x03]))])
        let members = try ArReader(data: data).members()
        XCTAssertEqual(members.count, 1)
        XCTAssertEqual(members[0].data, Data([0x01, 0x02, 0x03]))
    }

    // MARK: Negative cases

    func testRejectsNonArData() {
        XCTAssertThrowsError(try ArReader(data: Data("definitely not a deb".utf8)).members()) { error in
            XCTAssertEqual(error as? ArError, .notAnArArchive)
        }
        XCTAssertThrowsError(try ArReader(data: Data([0x21, 0x3c, 0x61, 0x72])).members()) { error in
            XCTAssertEqual(error as? ArError, .tooShort)
        }
    }

    func testTruncatedMemberHeader() {
        var data = Data("!<arch>\n".utf8)
        data.append(Data(repeating: 0x41, count: 20))
        XCTAssertThrowsError(try ArReader(data: data).members()) { error in
            XCTAssertEqual(error as? ArError, .malformedMemberHeader)
        }
    }

    func testMemberDataOutOfRange() {
        let deb = Fixtures.ar([("member", Data("junk".utf8))])
        var truncated = deb
        truncated.removeLast(4)
        XCTAssertThrowsError(try ArReader(data: truncated).members()) { error in
            XCTAssertEqual(error as? ArError, .memberDataOutOfRange(name: "member", size: 4))
        }
    }

    func testMissingDebianBinary() {
        let deb = Fixtures.ar([("control.tar", Data("x".utf8))])
        XCTAssertThrowsError(try DebArchive(debData: deb)) { error in
            XCTAssertEqual(error as? DebError, .missingDebianBinary)
        }
    }

    func testUnsupportedDebianVersion() {
        let deb = Fixtures.ar([("debian-binary", Data("3.0\n".utf8))])
        XCTAssertThrowsError(try DebArchive(debData: deb)) { error in
            XCTAssertEqual(error as? DebError, .unsupportedDebianVersion("3.0"))
        }
    }

    func testUnsupportedControlCompression() {
        let deb = Fixtures.ar([
            ("debian-binary", Data("2.0\n".utf8)),
            ("control.tar.zst", Data("x".utf8)),
        ])
        XCTAssertThrowsError(try DebArchive(debData: deb)) { error in
            XCTAssertEqual(error as? DebError, .unsupportedControlCompression("control.tar.zst"))
        }
    }

    func testMissingControlMember() {
        let deb = Fixtures.ar([("debian-binary", Data("2.0\n".utf8))])
        XCTAssertThrowsError(try DebArchive(debData: deb)) { error in
            XCTAssertEqual(error as? DebError, .missingControlMember)
        }
    }
}
