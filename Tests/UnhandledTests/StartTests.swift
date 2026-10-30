import Foundation
@testable import Unhandled
import XCTest

final class StartTests: SDKTestCase {
    private let service = "0b4f6c2e-8a1d-4c3e-9f7a-1234567890ab"

    // Same cases as packages/react-native/tests/dsn.test.ts, with what the protocol parser returns for each.
    func testDsnTableMatchesTheProtocolParser() async {
        let cases: [(dsn: String, endpoint: String?)] = [
            ("https://uh_live_7Hq2xR9vLp3sKd8mWn4tYb6c@ingest.example.com/\(service)", "https://ingest.example.com"),
            ("https://uh_test_abcdefghijklmnop@Ingest.Example.com:443/\(service.uppercased())", "https://ingest.example.com"),
            ("http://uh_test_abcdefghijklmnop@127.0.0.1:4318/\(service)", "http://127.0.0.1:4318"),
            ("https://mk_live_abcdefghijklmnop@ingest.example.com/\(service)", "https://ingest.example.com"),
            ("https://uh_live_abcdefghijklmnop:secret@ingest.example.com/\(service)", nil),
            ("https://uh_live_abcdefghijklmnop@ingest.example.com/\(service)?x=1", nil),
            ("https://uh_live_abcdefghijklmnop@ingest.example.com/\(service)#frag", nil),
            ("https://ingest.example.com/\(service)", nil),
            ("https://nope@ingest.example.com/\(service)", nil),
            ("https://uh_live_abcdefghijklmnop@ingest.example.com/not-a-service", nil),
            ("ftp://uh_live_abcdefghijklmnop@ingest.example.com/\(service)", nil),
            ("", nil),
        ]
        for (dsn, endpoint) in cases {
            let host = FakeHost()
            let client = start(host, dsn: dsn)
            XCTAssertEqual(client.isActive, endpoint != nil, dsn)
            client.captureMessage("hello")
            await client.flush()
            XCTAssertEqual(host.sent.first?.url, endpoint.map { "\($0)/v1/logs" }, dsn)
            if endpoint != nil {
                XCTAssertEqual(host.sent.first?.headers["x-unhandled-service-id"], service, dsn)
            }
            await client.shutdown()
        }
    }

    func testHeadersCarryKeyServiceAndEnvironment() async {
        let client = start { $0.environment = .staging }
        client.captureMessage("hello")
        await client.flush()
        XCTAssertEqual(host.sent.first?.headers, [
            "x-api-key": "uh_live_7Hq2xR9vLp3sKd8mWn4tYb6c",
            "x-unhandled-service-id": service,
            "x-unhandled-env": "staging",
            "content-type": "application/json",
        ])
    }

    func testDisabledClientIsInactiveAndSendsNothing() async {
        let client = start { $0.enabled = false }
        XCTAssertFalse(client.isActive)
        XCTAssertNil(client.release)
        client.track("opened")
        client.captureMessage("hello")
        XCTAssertEqual(client.getVariant("paywall", variants: ["control", "green"]), "control")
        await client.flush()
        XCTAssertEqual(host.sent.count, 0)
        XCTAssertEqual(host.envelopeFiles, [])
    }

    func testSecondStartKeepsTheFirstClient() {
        let first = start()
        let second = start(FakeHost()) { $0.release = "other" }
        XCTAssertTrue(first === second)
        XCTAssertTrue(Unhandled.shared === first)
    }

    func testSharedIsInactiveBeforeStartAndAfterShutdown() async {
        XCTAssertFalse(Unhandled.shared.isActive)
        let client = start()
        XCTAssertTrue(Unhandled.shared.isActive)
        await client.shutdown()
        XCTAssertFalse(Unhandled.shared.isActive)
        XCTAssertEqual(host.crashInstalls, 1)
        XCTAssertEqual(host.crashUninstalls, 1)
        XCTAssertTrue(start(FakeHost()).isActive)
    }

    func testReleaseDefaultsToBundleVersionAndBuildAndExplicitWins() async {
        let client = start()
        XCTAssertEqual(client.release, "com.example.app@1.4.0+42")
        client.captureMessage("hello")
        await client.flush()
        XCTAssertEqual(host.errors.first?.resource, [
            "service.version": "com.example.app@1.4.0+42",
            "telemetry.sdk.language": "swift",
            "telemetry.sdk.name": "@unhandled/swift",
            "telemetry.sdk.version": "0.1.0",
            "unhandled.sdk.name": "@unhandled/swift",
            "unhandled.sdk.version": "0.1.0",
            "os.name": "iOS",
            "os.version": "19.1",
            "device.class": "phone",
        ])
        await client.shutdown()
        XCTAssertEqual(start(FakeHost()) { $0.release = "custom-7" }.release, "custom-7")
    }

    func testCaptureCrashesFalseInstallsNoHandlers() {
        start { $0.captureCrashes = false }
        XCTAssertEqual(host.crashInstalls, 0)
    }
}
