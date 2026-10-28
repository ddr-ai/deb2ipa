import XCTest
import DebKit

final class DebianVersionTests: XCTestCase {

    private func assertOrder(_ lhs: String, _ rhs: String, _ expected: Int,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let a = DebianVersion(lhs), let b = DebianVersion(rhs) else {
            XCTFail("Failed to parse " + lhs + " or " + rhs, file: file, line: line)
            return
        }
        let result = DebianVersion.compare(a, b)
        XCTAssertEqual(result > 0 ? 1 : (result < 0 ? -1 : 0), expected,
                       lhs + " vs " + rhs, file: file, line: line)
    }

    func testBasicOrdering() {
        assertOrder("1.0", "1.0", 0)
        assertOrder("1.0", "1.1", -1)
        assertOrder("1.1", "1.0", 1)
        assertOrder("1.2.3", "1.2.10", -1)
        assertOrder("0.9", "0.10", -1)
    }

    func testTildeSortsBeforeEverything() {
        assertOrder("1.0~beta", "1.0", -1)
        assertOrder("1.0", "1.0~beta", 1)
        assertOrder("1.0~", "1.0", -1)
        assertOrder("1.0~", "1.0~~", 1)
        assertOrder("1~", "1", -1)
        assertOrder("1.0~beta1", "1.0~beta2", -1)
    }

    func testEpochDominates() {
        assertOrder("2:0.1", "1:99.99", 1)
        assertOrder("0:1.0", "1.0", 0)
        assertOrder("10:1.0", "9:9.9", 1)
    }

    func testNumericDigitRuns() {
        assertOrder("1.05", "1.5", 0)
        assertOrder("1.2.3", "1.2.10", -1)
        assertOrder("0.9", "0.10", -1)
    }

    func testRevisions() {
        assertOrder("1.0", "1.0-1", -1)
        assertOrder("1.0-1", "1.0-2", -1)
        assertOrder("1.0-1", "1.0-1+b1", -1)
    }

    func testLettersBeforeNonLetters() {
        assertOrder("1.0a", "1.0-a", -1)
        assertOrder("1.0.a", "1.0a", 1)
    }

    func testParsingStructure() throws {
        let v = try XCTUnwrap(DebianVersion("2:3.0~beta1-18"))
        XCTAssertEqual(v.epoch, 2)
        XCTAssertEqual(v.upstream, "3.0~beta1")
        XCTAssertEqual(v.revision, "18")
        XCTAssertEqual(v.canonicalString, "2:3.0~beta1-18")

        let plain = try XCTUnwrap(DebianVersion("3.0~beta1-18"))
        XCTAssertEqual(plain.epoch, 0)
        XCTAssertEqual(plain.upstream, "3.0~beta1")
        XCTAssertEqual(plain.revision, "18")
        XCTAssertEqual(plain.canonicalString, "3.0~beta1-18")
    }

    func testInvalidVersions() {
        for bad in ["", "abc", "1.0:", "a:1.0", ":1.0", "1.0-", "1.0_beta",
                    "1:2:3", "1.0 ", "-1.0", "1.0!"] {
            XCTAssertNil(DebianVersion(bad), "expected " + bad + " to be rejected")
        }
    }

    func testConstraintSatisfaction() throws {
        let v = try XCTUnwrap(DebianVersion("1.5"))
        XCTAssertTrue(v.satisfies(VersionConstraint(op: .laterOrEqual, version: "1.0")))
        XCTAssertTrue(v.satisfies(VersionConstraint(op: .exact, version: "1.50")))
        XCTAssertTrue(v.satisfies(VersionConstraint(op: .earlierStrict, version: "2.0")))
        XCTAssertTrue(v.satisfies(VersionConstraint(op: .earlierOrEqual, version: "1.5")))
        XCTAssertFalse(v.satisfies(VersionConstraint(op: .laterStrict, version: "1.5")))
        XCTAssertFalse(v.satisfies(VersionConstraint(op: .exact, version: "1.0")))
        // A constraint version dpkg would reject can never be satisfied.
        XCTAssertFalse(v.satisfies(VersionConstraint(op: .exact, version: "not-a-version")))
    }
}
