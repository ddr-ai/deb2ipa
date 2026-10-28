import XCTest
import DebKit

final class DebControlParsingTests: XCTestCase {

    private let controlText = """
Package: ws.hbang.newterm3
Name: NewTerm 3
Version: 3.0~beta1-18
Architecture: iphoneos-arm64
Maintainer: Hawken <hawken@example.ws>
Section: Terminal
Priority: optional
Installed-Size: 1024
Depends: mobilesubstrate (>= 0.9.6000), preferenceloader (>= 2.2.3) | ellekit, firmware (>= 14.0)
Pre-Depends: firmware (>= 12.0)
Recommends: ws.hbang.common
Description: A terminal emulator for iOS
 A full-featured terminal designed from the
 ground up for touch.
 .
 Supports modern fonts and theming.
Homepage: https://example.ws/newterm
"""

    func testParsesAllModelledFields() throws {
        let control = try DebControlParser.parse(controlText)
        XCTAssertEqual(control.package, "ws.hbang.newterm3")
        XCTAssertEqual(control.name, "NewTerm 3")
        XCTAssertEqual(control.version, "3.0~beta1-18")
        XCTAssertEqual(control.architecture, "iphoneos-arm64")
        XCTAssertEqual(control.maintainer, "Hawken <hawken@example.ws>")
        XCTAssertEqual(control.section, "Terminal")
        XCTAssertEqual(control.priority, "optional")
        XCTAssertEqual(control.installedSize, 1024)
        XCTAssertEqual(control.homepage, "https://example.ws/newterm")
        XCTAssertEqual(control.summary, "A terminal emulator for iOS")
        XCTAssertEqual(control.longDescription,
                       "A full-featured terminal designed from the\nground up for touch.\n.\nSupports modern fonts and theming.")
    }

    func testParsesDependencies() throws {
        let control = try DebControlParser.parse(controlText)
        let depends = try XCTUnwrap(control.depends)
        XCTAssertEqual(depends.groups.count, 3)
        XCTAssertEqual(depends.groups[1].alternatives.map(\.packageName),
                       ["preferenceloader", "ellekit"])
        XCTAssertEqual(control.preDepends?.canonicalString, "firmware (>= 12.0)")
        XCTAssertEqual(control.recommends?.canonicalString, "ws.hbang.common")
        XCTAssertEqual(control.allDependencies.count, 4)
    }

    func testVersionRoundTrip() throws {
        let control = try DebControlParser.parse(controlText)
        let v = try XCTUnwrap(control.debianVersion)
        XCTAssertEqual(v.epoch, 0)
        XCTAssertEqual(v.upstream, "3.0~beta1")
        XCTAssertEqual(v.revision, "18")
    }

    func testMissingRequiredFields() {
        XCTAssertThrowsError(try DebControlParser.parse("Package: foo\n")) { error in
            XCTAssertEqual(error as? DebControlError, .missingRequiredField("Version"))
        }
        XCTAssertThrowsError(try DebControlParser.parse("Version: 1.0\n")) { error in
            XCTAssertEqual(error as? DebControlError, .missingRequiredField("Package"))
        }
    }

    func testMalformedLines() {
        XCTAssertThrowsError(try DebControlParser.parse("nocolonhere\n"))
        XCTAssertThrowsError(try DebControlParser.parse(" continuation without field\n"))
        XCTAssertThrowsError(try DebControlParser.parse(""))
    }

    func testCaseInsensitiveFieldLookup() throws {
        let control = try DebControlParser.parse("package: foo\nVERSION: 1.0\n")
        XCTAssertEqual(control.package, "foo")
        XCTAssertEqual(control.version, "1.0")
    }

    func testUnmodelledFieldsAvailableInAllFields() throws {
        let control = try DebControlParser.parse("Package: p\nVersion: 1.0\nX-Source-Repo: havoc\n")
        XCTAssertEqual(control.allFields["x-source-repo"], "havoc")
    }
}
