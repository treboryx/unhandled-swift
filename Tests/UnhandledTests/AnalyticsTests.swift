import Foundation
@testable import Unhandled
import XCTest

final class AnalyticsTests: SDKTestCase {
    private func bodies() async -> [[String: Value]] {
        await Unhandled.shared.flush()
        return host.analytics.compactMap { record in
            guard case let .map(body) = record.body else { return nil }
            return body
        }
    }

    private func onlyRecordText() -> String? {
        guard let body = host.sent.first(where: { $0.url.hasSuffix("/v1/logs") })?.body,
              let start = body.range(of: "\"logRecords\":["),
              body.hasSuffix("]}]}]}")
        else { return nil }
        return String(body[start.upperBound ..< body.index(body.endIndex, offsetBy: -6)])
    }

    func testIdentifyRecordIsByteCompatible() async {
        let client = start()
        client.identify("42", properties: ["seats": 3, "plan": "pro"])
        await client.flush()
        let expected = #"{"timeUnixNano":"1761800000000000000","observedTimeUnixNano":"1761800000000000000","severityNumber":9,"severityText":"INFO","body":{"kvlistValue":{"values":[{"key":"event_id","value":{"stringValue":"019a3376-9200-7400-8000-400000004000"}},{"key":"occurred_at_ms","value":{"intValue":"1761800000000"}},{"key":"kind","value":{"stringValue":"identify"}},{"key":"site","value":{"stringValue":""}},{"key":"path","value":{"stringValue":""}},{"key":"referrer","value":{"stringValue":""}},{"key":"properties","value":{"kvlistValue":{"values":[{"key":"plan","value":{"stringValue":"pro"}},{"key":"seats","value":{"intValue":"3"}}]}}}]}},"attributes":[{"key":"unhandled.analytics.version","value":{"stringValue":"1"}},{"key":"user.id","value":{"stringValue":"42"}}]}"#
        XCTAssertEqual(onlyRecordText(), expected)
        XCTAssertEqual(host.analytics.first?.scope, "unhandled.analytics")
    }

    func testIdentifyMakesTheErrorUserAndKeepsAMatchingEmail() async {
        let client = start()
        client.setUser(CaptureUser(id: "7", email: "ana@example.com"))
        client.identify("7")
        client.captureMessage("same id")
        client.identify("8")
        client.captureMessage("other id")
        await client.flush()
        XCTAssertEqual(host.errors.map { [$0.attribute("user.id"), $0.attribute("user.email")] }, [
            ["7", "ana@example.com"], ["8", nil],
        ])
    }

    func testTrackSendsAnEventWithoutUserUntilIdentify() async {
        let client = start()
        client.track("checkout_started", properties: ["items": 2, "total": 19.5, "gift": true])
        client.identify("u1")
        client.track("checkout_done")
        let sent = await bodies()
        XCTAssertEqual(sent[0], [
            "event_id": "019a3376-9200-7400-8000-400000004000",
            "occurred_at_ms": 1_761_800_000_000,
            "kind": "event",
            "name": "checkout_started",
            "site": "", "path": "", "referrer": "",
            "properties": ["items": 2, "total": 19.5, "gift": true],
        ])
        XCTAssertNil(host.analytics[0].attributeMap["user.id"])
        XCTAssertEqual(host.analytics[0].attributeMap["unhandled.analytics.version"], "1")
        XCTAssertEqual(host.analytics[2].attributeMap["user.id"], "u1")
        XCTAssertEqual(sent.map { $0["kind"] }, ["event", "identify", "event"])
    }

    func testRevenueRecordCarriesTheRevenueBody() async {
        let client = start()
        client.trackRevenue(Revenue(
            amount: 1999, currency: "usd", id: "ch_1", product: "pro",
            subscription: .init(id: "sub_1", interval: .month), properties: ["coupon": "SPRING"]
        ))
        client.trackRevenue(Revenue(amount: -500, currency: "EUR"))
        let sent = await bodies()
        XCTAssertEqual(sent, [
            [
                "event_id": "ch_1", "occurred_at_ms": 1_761_800_000_000, "kind": "revenue", "name": "revenue",
                "site": "", "path": "", "referrer": "", "properties": ["coupon": "SPRING"],
                "revenue": [
                    "amount": 1999, "currency": "USD", "product": "pro", "subscription_id": "sub_1",
                    "subscription_interval": "month", "subscription_interval_count": 1,
                ],
            ],
            [
                "event_id": "019a3376-9200-7400-8000-400000004000", "occurred_at_ms": 1_761_800_000_000,
                "kind": "revenue", "name": "revenue", "site": "", "path": "", "referrer": "", "properties": [:],
                "revenue": [
                    "amount": -500, "currency": "EUR", "product": "", "subscription_id": "",
                    "subscription_interval": "", "subscription_interval_count": 0,
                ],
            ],
        ])
    }

    func testExposureRecordShape() async {
        let client = start()
        client.identify("u1")
        client.trackExposure("paywall", variant: "green")
        let sent = await bodies()
        XCTAssertEqual(sent.last, [
            "event_id": "019a3376-9200-7400-8000-400000004000", "occurred_at_ms": 1_761_800_000_000,
            "kind": "event", "name": "experiment_exposure", "site": "", "path": "", "referrer": "",
            "properties": ["experiment": "paywall", "variant": "green"],
        ])
        XCTAssertEqual(host.analytics.last?.attributeMap["user.id"], "u1")
    }

    func testSetUserPropertiesNeedsAnIdentity() async {
        let client = start()
        client.setUserProperties(["plan": "free"])
        client.identify("u1")
        client.setUserProperties(["plan": "pro"])
        client.reset()
        client.setUserProperties(["plan": "team"])
        let sent = await bodies()
        XCTAssertEqual(sent.map { $0["properties"] }, [[:], ["plan": "pro"]])
        XCTAssertEqual(host.analytics.map { $0.attributeMap["user.id"] }, ["u1", "u1"])
    }

    func testPropertyValidationTable() async {
        let client = start()
        let longKey = String(repeating: "k", count: 65)
        let longValue = String(repeating: "v", count: 257)
        let tooMany = Dictionary(uniqueKeysWithValues: (0 ... 20).map { ("p\($0)", AnalyticsValue.int($0)) })
        let twenty = Dictionary(uniqueKeysWithValues: (0 ..< 20).map { ("p\($0)", AnalyticsValue.int($0)) })
        let rejectedForEvents: [[String: AnalyticsValue]] = [
            tooMany, ["": 1], [longKey: 1], ["k": .string(longValue)], ["k": .double(.infinity)], ["k": .double(.nan)],
            ["user_id": 1], ["UserId": 1], ["EMAIL": 1], ["distinct_id": 1], ["anonymous_id": 1], ["session_id": 1],
            ["user.plan": 1], ["Trace.id": 1], ["span.x": 1], ["unhandled.x": 1],
        ]
        for properties in rejectedForEvents {
            client.track("event", properties: properties)
        }
        let accepted: [[String: AnalyticsValue]] = [
            twenty, [String(repeating: "k", count: 64): 1], ["k": .string(String(repeating: "é", count: 128))],
            ["user": "fine", "users.x": 1, "tab\t": "control chars are fine in events"],
        ]
        for properties in accepted {
            client.track("event", properties: properties)
        }
        let sent = await bodies()
        XCTAssertEqual(sent.count, accepted.count)
    }

    func testProfileRulesReserveOnlyTheVendorPrefixAndRefuseControlCharacters() async {
        let client = start()
        client.identify("u1", properties: ["email": "ana@example.com", "user.plan": "pro"])
        client.identify("u2", properties: ["unhandled.x": 1])
        client.identify("u3", properties: ["bad\u{0}key": 1])
        client.identify("u4", properties: ["k": "line\nbreak"])
        let sent = await bodies()
        XCTAssertEqual(sent.map { $0["properties"] }, [["email": "ana@example.com", "user.plan": "pro"]])
    }

    func testUserIdValidationTable() async {
        let client = start()
        for userId in ["", "   ", String(repeating: "u", count: 257), "a\u{7}b", "tab\tid"] {
            client.identify(userId)
        }
        client.identify(String(repeating: "u", count: 256))
        client.identify(" padded ")
        let sent = await bodies()
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(host.analytics.last?.attributeMap["user.id"], " padded ")
    }

    func testEventNameValidation() async {
        let client = start()
        for name in ["", "pageview", "revenue", String(repeating: "n", count: 101)] {
            client.track(name)
        }
        client.track(String(repeating: "n", count: 100))
        client.track("Revenue")
        let sent = await bodies()
        XCTAssertEqual(sent.count, 2)
    }

    func testRevenueValidationTable() async {
        let client = start()
        let rejected: [Revenue] = [
            Revenue(amount: 1_000_000_000_001, currency: "USD"),
            Revenue(amount: -1_000_000_000_001, currency: "USD"),
            Revenue(amount: .min, currency: "USD"),
            Revenue(amount: 1, currency: "US"),
            Revenue(amount: 1, currency: "US1"),
            Revenue(amount: 1, currency: "USDX"),
            Revenue(amount: 1, currency: "ÜSD"),
            Revenue(amount: 1, currency: "USD", id: "  "),
            Revenue(amount: 1, currency: "USD", id: String(repeating: "i", count: 65)),
            Revenue(amount: 1, currency: "USD", id: "a\nb"),
            Revenue(amount: 1, currency: "USD", product: String(repeating: "p", count: 129)),
            Revenue(amount: 1, currency: "USD", product: "a\u{0}b"),
            Revenue(amount: 1, currency: "USD", subscription: .init(id: " ", interval: .month)),
            Revenue(amount: 1, currency: "USD", subscription: .init(id: String(repeating: "s", count: 129), interval: .month)),
            Revenue(amount: 1, currency: "USD", subscription: .init(id: "s", interval: .day, intervalCount: 367)),
            Revenue(amount: 1, currency: "USD", subscription: .init(id: "s", interval: .week, intervalCount: 53)),
            Revenue(amount: 1, currency: "USD", subscription: .init(id: "s", interval: .month, intervalCount: 13)),
            Revenue(amount: 1, currency: "USD", subscription: .init(id: "s", interval: .year, intervalCount: 2)),
            Revenue(amount: 1, currency: "USD", subscription: .init(id: "s", interval: .month, intervalCount: 0)),
            Revenue(amount: 1, currency: "USD", properties: ["user_id": "x"]),
        ]
        rejected.forEach(client.trackRevenue)
        let accepted: [Revenue] = [
            Revenue(amount: 1_000_000_000_000, currency: "usd"),
            Revenue(amount: 0, currency: "JPY", product: String(repeating: "p", count: 128)),
            Revenue(amount: 1, currency: "USD", subscription: .init(id: "s", interval: .day, intervalCount: 366)),
            Revenue(amount: 1, currency: "USD", subscription: .init(id: "s", interval: .year)),
        ]
        accepted.forEach(client.trackRevenue)
        let sent = await bodies()
        XCTAssertEqual(sent.count, accepted.count)
    }
}
