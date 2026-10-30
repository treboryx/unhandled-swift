import Foundation
@testable import Unhandled
import XCTest

final class ExperimentGoldenTests: XCTestCase {
    func testHashAndBucketMatchTheProtocolGoldens() {
        let goldens: [(unit: String, hash: UInt32, bucket: String)] = [
            ("a", 3_333_694_715, "0.776186"),
            ("b", 837_012_278, "0.194882"),
            ("user-42", 1_503_773_764, "0.350125"),
            ("ünïcödé", 2_270_558_176, "0.528656"),
            ("", 3_644_004_012, "0.848436"),
            ("0", 144_068_709, "0.033544"),
            ("user@example.com", 4_217_040_050, "0.981856"),
            ("😀", 2_535_741_650, "0.590398"),
        ]
        for golden in goldens {
            XCTAssertEqual(hash32("checkout-button:" + golden.unit), golden.hash, golden.unit)
            let bucket = experimentBucket("checkout-button", unitId: golden.unit)
            XCTAssertEqual(String(format: "%.6f", bucket), golden.bucket, golden.unit)
        }
    }

    func testAssignmentMatchesTheProtocolGoldens() {
        let units = (1 ... 8).map { "user-\($0)" }
        let pricing = units.map {
            assignVariant("pricing-page", unitId: $0, variants: [Variant("control", weight: 3), Variant("green")])
        }
        XCTAssertEqual(pricing, ["control", "control", "green", "control", "green", "green", "control", "control"])
        let paywall = units.map { assignVariant("paywall", unitId: $0, variants: ["control", "green", "blue"]) }
        XCTAssertEqual(paywall, ["blue", "blue", "green", "green", "blue", "green", "green", "blue"])
    }
}

final class ExperimentClientTests: SDKTestCase {
    private func exposures() async -> [[String: Value]] {
        await Unhandled.shared.flush()
        return host.analytics.compactMap { record -> [String: Value]? in
            guard case let .map(body) = record.body, body["name"] == "experiment_exposure",
                  case let .map(properties) = body["properties"]
            else { return nil }
            return properties.merging(["user": record.attributeMap["user.id"] ?? "none"]) { first, _ in first }
        }
    }

    func testBeforeIdentifyReturnsControlAndSendsNothing() async {
        let client = start()
        XCTAssertEqual(client.getVariant("paywall", variants: ["control", "green", "blue"]), "control")
        client.trackExposure("paywall", variant: "green")
        let sent = await exposures()
        XCTAssertEqual(sent, [])
    }

    func testIdentifiedUserGetsTheirVariantAndOneExposurePerRun() async {
        let client = start()
        client.identify("user-1")
        XCTAssertEqual(client.getVariant("paywall", variants: ["control", "green", "blue"]), "blue")
        XCTAssertEqual(client.getVariant("paywall", variants: ["control", "green", "blue"]), "blue")
        client.identify("user-3")
        XCTAssertEqual(client.getVariant("paywall", variants: ["control", "green", "blue"]), "green")
        let sent = await exposures()
        XCTAssertEqual(sent, [
            ["experiment": "paywall", "variant": "blue", "user": "user-1"],
            ["experiment": "paywall", "variant": "green", "user": "user-3"],
        ])
    }

    func testTrackExposureSendsEveryCallAfterIdentifyWhenKeysAreValid() async {
        let client = start()
        client.identify("u1")
        client.trackExposure("paywall", variant: "green")
        client.trackExposure("paywall", variant: "green")
        client.trackExposure("Paywall", variant: "green")
        client.trackExposure("paywall", variant: "")
        let sent = await exposures()
        XCTAssertEqual(sent.count, 2)
    }

    func testInvalidExperimentsFallBackToControlWithoutExposure() async {
        let client = start()
        client.identify("user-1")
        let invalid: [(String, [Variant])] = [
            ("Bad Key", ["control", "green"]),
            ("paywall", ["control"]),
            ("paywall", ["a", "b", "c", "d", "e", "f"]),
            ("paywall", ["control", "control"]),
            ("paywall", ["control", "Green"]),
            ("paywall", [Variant("control", weight: 0), "green"]),
            ("paywall", [Variant("control", weight: 101), "green"]),
            ("-paywall", ["control", "green"]),
            (String(repeating: "a", count: 65), ["control", "green"]),
        ]
        for (experiment, variants) in invalid {
            XCTAssertEqual(client.getVariant(experiment, variants: variants), variants[0].key, experiment)
        }
        XCTAssertEqual(client.getVariant("x", variants: []), "")
        let sent = await exposures()
        XCTAssertEqual(sent, [])
    }

    func testValidEdgeKeysAreAccepted() async {
        let client = start()
        client.identify("user-1")
        let key = "a" + String(repeating: "_", count: 63)
        _ = client.getVariant(key, variants: [Variant("0", weight: 100), Variant("b-c", weight: 1)])
        let sent = await exposures()
        XCTAssertEqual(sent.count, 1)
    }

    func testResetReturnsToControlAndForgetsTheUser() async {
        let client = start()
        client.identify("user-1")
        client.reset()
        XCTAssertEqual(client.getVariant("paywall", variants: ["control", "green", "blue"]), "control")
        client.captureMessage("after reset")
        await client.flush()
        XCTAssertNil(host.errors.last?.attribute("user.id"))
    }
}
