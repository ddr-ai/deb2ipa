import XCTest
import DebKit

final class DependencyParsingTests: XCTestCase {

    func testSimpleName() throws {
        let expr = try DependsExpression(parsing: "mobilesubstrate")
        XCTAssertEqual(expr.groups.count, 1)
        XCTAssertEqual(expr.canonicalString, "mobilesubstrate")
        let alt = try XCTUnwrap(expr.groups.first?.alternatives.first)
        XCTAssertEqual(alt.packageName, "mobilesubstrate")
        XCTAssertEqual(alt.versionConstraints, [])
        XCTAssertEqual(alt.architectures, [])
    }

    func testVersionConstraint() throws {
        let expr = try DependsExpression(parsing: "firmware (>= 12.0)")
        let alt = try XCTUnwrap(expr.groups.first?.alternatives.first)
        XCTAssertEqual(alt.packageName, "firmware")
        XCTAssertEqual(alt.versionConstraints, [VersionConstraint(op: .laterOrEqual, version: "12.0")])
    }

    func testAllOperators() throws {
        let expr = try DependsExpression(
            parsing: "p (<< 1.0), q (<= 2.0), r (= 3.0), s (>= 4.0), t (>> 5.0)")
        let ops = expr.groups.compactMap { $0.alternatives.first?.versionConstraints.first?.op }
        XCTAssertEqual(ops, [.earlierStrict, .earlierOrEqual, .exact, .laterOrEqual, .laterStrict])
    }

    func testAlternativesGroup() throws {
        let expr = try DependsExpression(parsing: "preferenceloader (>= 2.2.3) | ellekit")
        XCTAssertEqual(expr.groups.count, 1)
        let group = try XCTUnwrap(expr.groups.first)
        XCTAssertEqual(group.alternatives.map(\.packageName), ["preferenceloader", "ellekit"])
        XCTAssertEqual(group.alternatives[0].versionConstraints,
                       [VersionConstraint(op: .laterOrEqual, version: "2.2.3")])
        XCTAssertEqual(group.alternatives[1].versionConstraints, [])
    }

    func testMultipleGroups() throws {
        let expr = try DependsExpression(parsing: "a, b, c")
        XCTAssertEqual(expr.groups.map { $0.alternatives.first?.packageName }, ["a", "b", "c"])
    }

    func testMultipleConstraints() throws {
        let expr = try DependsExpression(parsing: "libc (>= 0.2) (<< 0.4)")
        let alt = try XCTUnwrap(expr.groups.first?.alternatives.first)
        XCTAssertEqual(alt.versionConstraints, [
            VersionConstraint(op: .laterOrEqual, version: "0.2"),
            VersionConstraint(op: .earlierStrict, version: "0.4"),
        ])
    }

    func testArchitectureQualifiers() throws {
        let brackets = try DependsExpression(parsing: "foo [iphoneos-arm64]")
        XCTAssertEqual(brackets.groups.first?.alternatives.first?.architectures,
                       ["iphoneos-arm64"])
        let angles = try DependsExpression(parsing: "foo <arm64 arm64e>")
        XCTAssertEqual(angles.groups.first?.alternatives.first?.architectures,
                       ["arm64", "arm64e"])
    }

    func testWhitespaceTolerance() throws {
        let expr = try DependsExpression(parsing: "  a   ( >= 1 )  |  b  ")
        let group = try XCTUnwrap(expr.groups.first)
        XCTAssertEqual(group.alternatives.map(\.packageName), ["a", "b"])
        XCTAssertEqual(group.alternatives[0].versionConstraints.first?.version, "1")
    }

    func testCanonicalStringRoundTrip() throws {
        let expr = try DependsExpression(
            parsing: "preferenceloader (>= 2.2.3) | ellekit, mobilesubstrate")
        XCTAssertEqual(expr.canonicalString,
                       "preferenceloader (>= 2.2.3) | ellekit, mobilesubstrate")
    }

    func testStrictSplitting() {
        XCTAssertThrowsError(try DependsExpression(parsing: "a |")) { error in
            XCTAssertEqual(error as? DependencyParseError, .emptyAlternative(" "))
        }
        XCTAssertThrowsError(try DependsExpression(parsing: "a,,b")) { error in
            XCTAssertEqual(error as? DependencyParseError, .emptyAlternative(""))
        }
    }

    func testMalformedInputs() {
        XCTAssertThrowsError(try DependsExpression(parsing: "a (>= )"))
        XCTAssertThrowsError(try DependsExpression(parsing: "a (=> 1)"))
        XCTAssertThrowsError(try DependsExpression(parsing: "a [unclosed"))
        XCTAssertThrowsError(try DependsExpression(parsing: "a b"))
        XCTAssertThrowsError(try DependsExpression(parsing: ""))
    }
}
