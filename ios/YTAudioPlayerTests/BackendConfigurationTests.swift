import XCTest
@testable import PeacePlayer

final class BackendConfigurationTests: XCTestCase {
    func testOriginNormalizationAndRejection() throws {
        XCTAssertEqual(try BackendConfiguration.normalizedOrigin(" HTTPS://Example.COM:443/ ").absoluteString,
            "https://example.com")
        XCTAssertEqual(try BackendConfiguration.normalizedOrigin("http://localhost:8181/").absoluteString,
            "http://localhost:8181")
        for invalid in ["file:///tmp", "http://user:pass@host", "http://host/path", "http://host?q=a", "host", "http://host:0"] {
            XCTAssertThrowsError(try BackendConfiguration.normalizedOrigin(invalid), invalid)
        }
    }

    func testHostChangeInvalidatesCapturedIdentityAndPersistsNormalizedOrigin() throws {
        let name = "BackendConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let config = BackendConfiguration(defaults: defaults, fallback: URL(string: "http://one:8181")!)
        let first = config.identity
        XCTAssertFalse(try config.update("http://ONE:8181/"))
        XCTAssertTrue(config.isCurrent(first))
        XCTAssertTrue(try config.update("http://two:8181/"))
        XCTAssertFalse(config.isCurrent(first))
        XCTAssertEqual(defaults.string(forKey: BackendConfiguration.defaultsKey), "http://two:8181")
        XCTAssertThrowsError(try config.update("invalid"))
        XCTAssertEqual(config.identity.origin.absoluteString, "http://two:8181")
    }

    func testReturnedPathsUseCapturedOriginAndRejectForeignCredentials() throws {
        let identity = BackendIdentity(origin: URL(string: "http://one:8181")!, generation: 1)
        XCTAssertEqual(try identity.resolve("/audio/song.m4a?token=fixture").host, "one")
        XCTAssertEqual(identity.url(path: "/sync/v2").absoluteString, "http://one:8181/sync/v2")
        XCTAssertThrowsError(try identity.resolve("http://two:8181/audio/song.m4a"))
        XCTAssertThrowsError(try identity.resolve("//two:8181/audio/song.m4a"))
    }
}
