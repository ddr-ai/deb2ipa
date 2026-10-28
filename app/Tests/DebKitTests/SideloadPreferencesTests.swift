import XCTest
@testable import DebKit

/// M6 sideload handoffs (AltStore scheme + share sheet) and the Settings
/// preferences model. Pure logic, so it runs on the Linux CI.
final class SideloadPreferencesTests: XCTestCase {

    // MARK: - AltStore scheme URL

    func testAltStoreInstallURLEncodesAnHTTPSURL() throws {
        let ipa = try XCTUnwrap(URL(string: "https://example.com/a.ipa"))
        let install = try XCTUnwrap(Sideload.altStoreInstallURL(for: ipa))

        XCTAssertEqual(install.scheme, "altstore")
        let absolute = install.absoluteString
        XCTAssertTrue(absolute.hasPrefix("altstore://install?url="),
                      "unexpected scheme shape: \(absolute)")

        // The payload must be fully percent-encoded (no raw scheme colons
        // or slashes inside a query value) and must decode back to the
        // original URL.
        let encoded = String(absolute.dropFirst("altstore://install?url=".count))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains(":"))
        XCTAssertEqual(encoded.removingPercentEncoding, "https://example.com/a.ipa")
    }

    func testAltStoreInstallURLRejectsNonHTTPSources() {
        let file = URL(fileURLWithPath: "/tmp/NewTerm.ipa")
        XCTAssertNil(Sideload.altStoreInstallURL(for: file))
        XCTAssertNil(Sideload.altStoreInstallURL(
            for: URL(fileURLWithPath: "Downloads/a.ipa")))
        if let ftp = URL(string: "ftp://example.com/a.ipa") {
            XCTAssertNil(Sideload.altStoreInstallURL(for: ftp))
        }
    }

    // MARK: - Handoff mapping

    func testHandoffAltStoreTarget() throws {
        let ipa = try XCTUnwrap(URL(string: "https://example.com/a.ipa"))
        let handoff = try XCTUnwrap(Sideload.handoff(ipaURL: ipa, target: .altStore))
        guard case .altStoreInstall(let install) = handoff else {
            return XCTFail("expected altStoreInstall, got \(handoff)")
        }
        XCTAssertEqual(install.scheme, "altstore")
    }

    func testHandoffAltStoreWithLocalFileReturnsNil() {
        // AltStore cannot fetch a local file - the UI must fall back to
        // the share sheet instead of opening a broken URL.
        let file = URL(fileURLWithPath: "/tmp/a.ipa")
        XCTAssertNil(Sideload.handoff(ipaURL: file, target: .altStore))
    }

    func testHandoffShareSheetAndAsk() throws {
        let ipa = try XCTUnwrap(URL(string: "https://example.com/a.ipa"))
        guard case .shareSheet(let shared) = Sideload.handoff(ipaURL: ipa,
                                                             target: .shareSheet)
        else { return XCTFail("expected shareSheet") }
        XCTAssertEqual(shared, ipa)

        // `.ask` maps to the share sheet as the safe default; the screen
        // offers the AltStore choice on top of it.
        guard case .shareSheet = Sideload.handoff(ipaURL: ipa, target: .ask)
        else { return XCTFail("expected shareSheet for .ask") }

        // Local files still share fine via the share sheet.
        let file = URL(fileURLWithPath: "/tmp/a.ipa")
        guard case .shareSheet = Sideload.handoff(ipaURL: file, target: .shareSheet)
        else { return XCTFail("expected shareSheet for local file") }
    }

    // MARK: - Asset detection

    func testIsIPAAsset() {
        XCTAssertTrue(Sideload.isIPAAsset(named: "NewTerm.ipa"))
        XCTAssertTrue(Sideload.isIPAAsset(named: "newterm.IPA"))
        XCTAssertFalse(Sideload.isIPAAsset(named: "resolution-report.json"))
        XCTAssertFalse(Sideload.isIPAAsset(named: "app.deb"))
        XCTAssertFalse(Sideload.isIPAAsset(named: "ipaside"))
    }

    // MARK: - AppPreferences defaults

    func testDefaultPreferences() {
        let prefs = AppPreferences.default
        XCTAssertEqual(prefs.repository, "ddr-ai/deb2ipa")
        XCTAssertEqual(prefs.workflowFile, "build-ipa.yml")
        XCTAssertEqual(prefs.repos, AppPreferences.defaultRepos)
        XCTAssertEqual(prefs.repos.first, "https://repo.chariz.com/")
        XCTAssertEqual(prefs.installTarget, .ask)
    }

    func testWorkflowBasenameStripsPaths() {
        XCTAssertEqual(AppPreferences().workflowBasename, "build-ipa.yml")
        var prefs = AppPreferences()
        prefs.workflowFile = ".github/workflows/build-ipa.yml"
        XCTAssertEqual(prefs.workflowBasename, "build-ipa.yml")
    }

    func testRepositoryValidation() {
        XCTAssertTrue(AppPreferences(repository: "ddr-ai/deb2ipa").repositoryLooksValid)
        XCTAssertTrue(AppPreferences(repository: "a.b_c/d-e.f").repositoryLooksValid)
        XCTAssertFalse(AppPreferences(repository: "ddr-ai").repositoryLooksValid)
        XCTAssertFalse(AppPreferences(repository: "a/b/c").repositoryLooksValid)
        XCTAssertFalse(AppPreferences(repository: "/x").repositoryLooksValid)
        XCTAssertFalse(AppPreferences(repository: "owner/re po").repositoryLooksValid)
        XCTAssertFalse(AppPreferences(repository: "").repositoryLooksValid)
    }

    // MARK: - Preferences round-trips

    func testInMemoryStoreRoundTrip() throws {
        let store = InMemoryPreferencesStore()
        XCTAssertNil(try store.load())

        var prefs = AppPreferences.default
        prefs.repository = "example/tool"
        prefs.repos = ["https://apt.procurs.us/"]
        prefs.installTarget = .altStore
        try store.save(prefs)

        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded, prefs)
        XCTAssertEqual(loaded.installTarget, .altStore)
    }

    func testPreferencesJSONRoundTrip() throws {
        // The UserDefaults store persists a JSON blob; the Codable
        // conformance (incl. InstallTarget raw values) must survive it.
        var prefs = AppPreferences.default
        prefs.installTarget = .shareSheet
        prefs.repos = ["https://repo.chariz.com/", "https://apt.procurs.us/"]
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)
        XCTAssertEqual(decoded, prefs)
        XCTAssertEqual(decoded.installTarget, .shareSheet)
    }

    func testInstallTargetLabels() {
        // The Settings picker labels are non-empty and distinct.
        var seen = Set<String>()
        for target in InstallTarget.allCases {
            XCTAssertFalse(target.label.isEmpty)
            XCTAssertTrue(seen.insert(target.label).inserted)
        }
        XCTAssertEqual(InstallTarget.allCases.count, 3)
    }
}
