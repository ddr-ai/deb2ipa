import XCTest
@testable import DebKit

/// M6 import pipeline: every parser failure maps to a typed, explained
/// ImportFailure - the Import screen never sees an exception.
final class ImportPipelineTests: XCTestCase {

    // MARK: - Happy paths

    func testConvertibleAppDebImports() throws {
        let outcome = DebImporter.importDeb(data: ClassifierFixtures.appStandard,
                                            filename: "hello.deb")
        guard case .imported(let package, let classification) = outcome else {
            return XCTFail("expected imported, got \(outcome)")
        }
        XCTAssertEqual(classification.class, .app)
        XCTAssertTrue(classification.isConvertible)
        XCTAssertTrue(outcome.isConvertible)
        XCTAssertEqual(outcome.package?.control.package,
                       package.control.package)
    }

    func testTweakDebImportsButIsNotConvertible() throws {
        let outcome = DebImporter.importDeb(data: ClassifierFixtures.tweak,
                                            filename: "tweak.deb")
        guard case .imported(_, let classification) = outcome else {
            return XCTFail("expected imported, got \(outcome)")
        }
        XCTAssertEqual(classification.class, .tweak)
        XCTAssertFalse(classification.isConvertible)
        XCTAssertFalse(outcome.isConvertible)
    }

    func testPlaceholderFixtureFailsGracefullyOrImports() {
        // The NewTerm-style fixture's executable is a placeholder string,
        // not a Mach-O: the import itself must still succeed with the
        // .app class (the verdict says not convertible).
        let outcome = DebImporter.importDeb(data: Fixtures.debXZ,
                                            filename: "newterm.deb")
        guard case .imported(_, let classification) = outcome else {
            return XCTFail("fixture must import: \(outcome)")
        }
        XCTAssertEqual(classification.class, .app)
    }

    // MARK: - Typed failures

    func testEmptyDataFailsWithTypeEmptyFile() {
        let outcome = DebImporter.importDeb(data: Data(), filename: "empty.deb")
        guard case .failed(let failure) = outcome else {
            return XCTFail("expected failure, got \(outcome)")
        }
        XCTAssertEqual(failure.kind, .emptyFile)
        XCTAssertTrue(failure.userMessage.contains("empty"))
        XCTAssertFalse(failure.userMessage.isEmpty)
    }

    func testRandomBytesFailWithTypeNotADeb() {
        var bytes = Data(repeating: 0x41, count: 1024)
        bytes[0] = 0x50; bytes[1] = 0x4B  // zip magic
        let outcome = DebImporter.importDeb(data: bytes, filename: "fake.ipa")
        guard case .failed(let failure) = outcome else {
            return XCTFail("expected failure, got \(outcome)")
        }
        XCTAssertEqual(failure.kind, .notADeb)
        XCTAssertTrue(failure.userMessage.contains("not a Debian package"))
    }

    func testTooShortDataFailsWithTypeNotADeb() {
        let outcome = DebImporter.importDeb(data: Data("<ar".utf8),
                                            filename: "short.deb")
        XCTAssertEqual(outcome.failure?.kind, .notADeb)
    }

    func testArWithoutDebianBinaryIsNotADeb() {
        // A genuine ar archive that is not a deb container.
        let ar = Fixtures.ar([(name: "member.one", data: Data("x".utf8))])
        let outcome = DebImporter.importDeb(data: ar, filename: "ar.deb")
        XCTAssertEqual(outcome.failure?.kind, .notADeb)
    }

    func testArWithOnlyDebianBinaryFailsMissingControl() {
        let ar = Fixtures.ar([(name: "debian-binary", data: Data("2.0".utf8))])
        let outcome = DebImporter.importDeb(data: ar, filename: "nocontrol.deb")
        XCTAssertEqual(outcome.failure?.kind, .missingControl)
        XCTAssertTrue(outcome.failure?.userMessage.contains("control") ?? false)
    }

    func testTruncatedArIsCorruptArchive() {
        // A real deb cut off mid data.tar member: the member header survives
        // and advertises more bytes than the file contains.
        var data = Fixtures.debXZ
        data.removeLast(400)
        let outcome = DebImporter.importDeb(data: data, filename: "trunc.deb")
        XCTAssertEqual(outcome.failure?.kind, .corruptArchive)
    }

    func testTooLargeFileFailsWithTypedTooLarge() {
        let outcome = DebImporter.importDeb(data: ClassifierFixtures.appStandard,
                                            filename: "big.deb",
                                            maxBytes: 16)
        XCTAssertEqual(outcome.failure?.kind, .tooLarge)
        XCTAssertTrue(outcome.failure?.userMessage.contains("larger than") ?? false)
    }

    // MARK: - Summary / accessors

    func testSummaryAndAccessors() {
        let ok = DebImporter.importDeb(data: ClassifierFixtures.appStandard)
        XCTAssertTrue(ok.summary.hasPrefix("imported "))
        XCTAssertNil(ok.failure)

        let bad = DebImporter.importDeb(data: Data(), filename: "x.deb")
        XCTAssertTrue(bad.summary.hasPrefix("failed kind="))
        XCTAssertNil(bad.package)
    }
}
