import XCTest
@testable import DebKit

/// M6 display models: the Import screen's metadata card and dependency
/// tree, derived from the real dpkg-built fixture.
final class OverviewAndDependencyTests: XCTestCase {

    private func importedFixture() throws -> DebPackage {
        try DebPackage(debData: Fixtures.debXZ)
    }

    // MARK: - DebOverview

    func testOverviewDerivesMetadataFromControl() throws {
        let package = try importedFixture()
        let classification = try package.classify()
        let overview = DebOverview(control: package.control,
                                    classification: classification,
                                    debSizeBytes: 1168)

        // Title prefers the human Name field.
        XCTAssertEqual(overview.title, "NewTerm 3")
        XCTAssertEqual(overview.packageID, "ws.hbang.newterm3")
        XCTAssertEqual(overview.version, "3.0~beta1-18")
        XCTAssertEqual(overview.architecture, "iphoneos-arm64")
        XCTAssertEqual(overview.maintainer, "Hawken <hawken@example.ws>")
        XCTAssertEqual(overview.section, "Terminal")
        // Installed-Size is KB in the control stanza.
        XCTAssertEqual(overview.installedSizeBytes, 1024 * 1024)
        XCTAssertEqual(overview.summary, "A terminal emulator for iOS")
        XCTAssertEqual(overview.class, classification.class)
        XCTAssertEqual(overview.isConvertible, classification.isConvertible)
    }

    func testMetadataRowsHideMissingValues() throws {
        let package = try importedFixture()
        let classification = try package.classify()
        let overview = DebOverview(control: package.control,
                                    classification: classification,
                                    debSizeBytes: 1168)
        let labels = overview.metadataRows.map(\.label)
        XCTAssertTrue(labels.contains("Package"))
        XCTAssertTrue(labels.contains("Version"))
        XCTAssertTrue(labels.contains("Installed size"))
        XCTAssertTrue(labels.contains("Deb size"))
        XCTAssertTrue(labels.contains("Priority"))  // present in the fixture control
    }

    func testByteFormatting() {
        XCTAssertEqual(DebOverview.formattedByteCount(0), "0 KB")
        XCTAssertEqual(DebOverview.formattedByteCount(512), "0.5 KB")
        XCTAssertEqual(DebOverview.formattedByteCount(1168 * 1024), "1.1 MB")
        XCTAssertEqual(DebOverview.formattedByteCount(3 * 1024 * 1024 * 1024),
                       "3.0 GB")
    }

    func testVerdictSentences() throws {
        func verdict(_ data: Data) throws -> String {
            let package = try DebPackage(debData: data)
            let classification = try package.classify()
            return DebOverview(control: package.control,
                               classification: classification,
                               debSizeBytes: 0).verdict
        }
        XCTAssertTrue(try verdict(ClassifierFixtures.appStandard)
                      .hasPrefix("Convertible"))
        XCTAssertTrue(try verdict(ClassifierFixtures.tweak)
                      .contains("MobileSubstrate tweak"))
        XCTAssertTrue(try verdict(ClassifierFixtures.theme)
                      .contains("themes or data files"))
        XCTAssertTrue(try verdict(ClassifierFixtures.nonIOS)
                      .contains("Linux or desktop"))
    }

    // MARK: - DependencyDisplay

    func testSectionsMatchFixtureControlFields() throws {
        let package = try importedFixture()
        let sections = DependencyDisplay.sections(for: package.control)

        XCTAssertEqual(sections.map(\.title),
                       ["Depends", "Pre-Depends", "Recommends"])

        let depends = try XCTUnwrap(sections.first)
        // mobilesubstrate (>= 0.9.6000), preferenceloader (>= 2.2.3) |
        // ellekit, firmware (>= 14.0)
        XCTAssertEqual(depends.rows.count, 3)
        XCTAssertEqual(depends.rows[0].primary, "mobilesubstrate (>= 0.9.6000)")
        XCTAssertTrue(depends.rows[0].hasVersionConstraints)
        XCTAssertEqual(depends.rows[1].primary, "preferenceloader (>= 2.2.3)")
        XCTAssertEqual(depends.rows[1].alternatives, ["ellekit"])
        XCTAssertEqual(depends.rows[1].canonicalString,
                       "preferenceloader (>= 2.2.3) | ellekit")
        XCTAssertEqual(depends.rows[2].primary, "firmware (>= 14.0)")

        XCTAssertEqual(sections[1].rows.first?.primary, "firmware (>= 12.0)")
        XCTAssertEqual(sections[2].rows.first?.primary, "ws.hbang.common")
    }

    func testSummaryCounts() throws {
        let package = try importedFixture()
        let sections = DependencyDisplay.sections(for: package.control)
        // 3 Depends + 1 Pre-Depends + 1 Recommends = 5 rows,
        // one of which has alternatives.
        XCTAssertEqual(DependencyDisplay.summary(for: sections),
                       "5 dependencies, 1 with alternative")
        XCTAssertEqual(DependencyDisplay.summary(for: []),
                       "No dependencies")
    }

    func testRowsForHandBuiltExpression() throws {
        let expression = try DependsExpression(
            parsing: "a (>= 1.0) | b | c, bare")
        let rows = DependencyDisplay.rows(for: expression)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].primary, "a (>= 1.0)")
        XCTAssertEqual(rows[0].alternatives, ["b", "c"])
        XCTAssertTrue(rows[0].hasVersionConstraints)
        XCTAssertEqual(rows[1].primary, "bare")
        XCTAssertFalse(rows[1].hasVersionConstraints)
    }
}
