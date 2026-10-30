import Foundation
@testable import Unhandled
import XCTest

private enum CheckoutError: Error {
    case declined
}

private struct PaymentError: LocalizedError {
    var errorDescription: String? { "card declined" }
}

final class ErrorTests: SDKTestCase {
    func testMessageRecordIsExactlyTheReactNativeShape() async {
        let client = start()
        client.setUser(CaptureUser(id: "7", email: "ana@example.com", name: "Ana"))
        client.trackScreen("Checkout")
        client.captureMessage("payment slow", level: .warning, context: CaptureContext(
            tags: ["flow": "checkout", "os.name": "custom"],
            extra: ["attempt": 3]
        ))
        await client.flush()

        let record = host.errors[0]
        XCTAssertEqual(record.severityNumber, 13)
        XCTAssertEqual(record.severityText, "WARN")
        XCTAssertEqual(record.timeUnixNano, "1761800000000000000")
        XCTAssertEqual(record.observedTimeUnixNano, record.timeUnixNano)
        XCTAssertEqual(record.body, "payment slow")
        XCTAssertEqual(record.attributes.map(\.key), [
            "exception.type", "exception.message", "exception.stacktrace", "unhandled.exception.values",
            "unhandled.exception.values_version", "unhandled.exception.frames", "unhandled.log.source",
            "unhandled.exception.occurrence_id", "unhandled.message.level", "app.screen.name",
            "unhandled.tag.os.name", "unhandled.tag.device.class", "unhandled.tag.flow", "unhandled.extra.attempt",
            "user.id", "user.email", "user.name",
        ])
        XCTAssertEqual(record.attributeMap, [
            "exception.type": "Message",
            "exception.message": "payment slow",
            "exception.stacktrace": "",
            "unhandled.exception.values": #"[{"id":0,"parent_id":null,"source":null,"type":"Message","message":"payment slow","stacktrace":"","frames":[],"mechanism":{"type":"manual","handled":true,"synthetic":true,"exception_id":0,"parent_id":null,"source":null,"is_exception_group":false}}]"#,
            "unhandled.exception.values_version": "1",
            "unhandled.exception.frames": "[]",
            "unhandled.log.source": "exception_reporter",
            "unhandled.exception.occurrence_id": "019a3376-9200-7400-8000-400000004000",
            "unhandled.message.level": "warning",
            "app.screen.name": "Checkout",
            "unhandled.tag.os.name": "custom",
            "unhandled.tag.device.class": "phone",
            "unhandled.tag.flow": "checkout",
            "unhandled.extra.attempt": "3",
            "user.id": "7",
            "user.email": "ana@example.com",
            "user.name": "Ana",
        ])
    }

    func testMessageLevelsMapToSeverity() async {
        let client = start()
        for level in MessageLevel.allCases {
            client.captureMessage(level.rawValue, level: level)
        }
        await client.flush()
        XCTAssertEqual(host.errors.map(\.severityText), ["DEBUG", "INFO", "INFO", "WARN", "ERROR", "FATAL"])
        XCTAssertEqual(host.errors.map(\.severityNumber), [5, 9, 9, 13, 17, 21])
    }

    func testCapturedErrorIsAHandledManualErrorWithItsCause() async throws {
        let client = start()
        let cause = NSError(domain: "NSURLErrorDomain", code: -1009, userInfo: [NSLocalizedDescriptionKey: "offline"])
        let error = NSError(domain: "com.example.checkout", code: 7, userInfo: [
            NSLocalizedDescriptionKey: "checkout failed",
            NSUnderlyingErrorKey: cause,
        ])
        client.captureError(error, context: CaptureContext(user: CaptureUser(id: "context-user")))
        await client.flush()

        let record = host.errors[0]
        XCTAssertEqual(record.severityText, "ERROR")
        XCTAssertEqual(record.body, "checkout failed")
        XCTAssertEqual(record.attribute("exception.type"), "com.example.checkout (7)")
        XCTAssertEqual(record.attribute("exception.message"), "checkout failed")
        XCTAssertEqual(record.attribute("user.id"), "context-user")
        XCTAssertEqual(
            record.attribute("unhandled.exception.cause_chain"),
            #"[{"type":"NSURLErrorDomain (-1009)","message":"offline"}]"#
        )
        XCTAssertTrue(try XCTUnwrap(record.attribute("exception.stacktrace")).hasSuffix("\n[cause]: "))

        let values = try XCTUnwrap(jsonObject(record.attribute("unhandled.exception.values")) as? [[String: Any]])
        XCTAssertEqual(values.count, 2)
        let root = try XCTUnwrap(values[0]["mechanism"] as? [String: Any])
        XCTAssertEqual(root["type"] as? String, "manual")
        XCTAssertEqual(root["handled"] as? Bool, true)
        XCTAssertEqual(root["synthetic"] as? Bool, false)
        XCTAssertEqual(values[1]["source"] as? String, "cause")
        XCTAssertEqual(values[1]["parent_id"] as? Int, 0)

        let frames = try XCTUnwrap(jsonObject(record.attribute("unhandled.exception.frames")) as? [[String: Any]])
        let top = try XCTUnwrap(frames.first)
        XCTAssertEqual(Array(top.keys).filter { ["filename", "function", "lineno", "colno", "in_app", "instruction_addr"].contains($0) }.count, 6)
        XCTAssertFalse(try XCTUnwrap(top["function"] as? String).hasPrefix("$s9Unhandled"), "SDK frames are dropped")
        XCTAssertTrue(try XCTUnwrap(top["instruction_addr"] as? String).hasPrefix("0x"))
    }

    func testSwiftErrorsUseTheirTypeAndDescription() async {
        let client = start()
        client.captureError(CheckoutError.declined)
        client.captureError(PaymentError())
        await client.flush()
        XCTAssertEqual(host.errors.map { $0.attribute("exception.type") }, [
            "UnhandledTests.CheckoutError", "UnhandledTests.PaymentError",
        ])
        XCTAssertEqual(host.errors.map { $0.attribute("exception.message") }, ["declined", "card declined"])
    }

    func testTheSameErrorObjectIsReportedOnce() async {
        let client = start()
        let error = NSError(domain: "x", code: 1)
        client.captureError(error)
        client.captureError(error)
        client.captureError(NSError(domain: "x", code: 1))
        await client.flush()
        XCTAssertEqual(host.errors.count, 2)
    }

    func testIgnoreRulesMatchMessageOrPredicate() async {
        let client = start {
            $0.ignoreErrors = ["cancelled", .matching { $0.type.contains("Noise") }]
        }
        client.captureError(NSError(domain: "a", code: 1, userInfo: [NSLocalizedDescriptionKey: "request cancelled"]))
        client.captureError(NSError(domain: "Noise", code: 1))
        client.captureError(NSError(domain: "b", code: 2, userInfo: [NSLocalizedDescriptionKey: "kept"]))
        await client.flush()
        XCTAssertEqual(host.errors.map { $0.attribute("exception.message") }, ["kept"])
    }

    func testSampleRateDropsErrorsButNotMessages() async {
        host.randomValue = 0.6
        let client = start { $0.sampleRate = 0.5 }
        client.captureError(NSError(domain: "dropped", code: 1))
        client.captureMessage("kept")
        await client.flush()
        XCTAssertEqual(host.errors.map { $0.attribute("exception.message") }, ["kept"])
    }

    func testNonFiniteSampleRateMeansEverything() async {
        host.randomValue = 0.99
        let client = start { $0.sampleRate = .nan }
        client.captureError(NSError(domain: "kept", code: 1))
        await client.flush()
        XCTAssertEqual(host.errors.count, 1)
    }

    func testAnErrorIsOnDiskBeforeCaptureReturns() async {
        host.holdSends = true
        let client = start()
        client.captureError(NSError(domain: "x", code: 1))
        XCTAssertEqual(host.envelopeFiles.count, 1)
        XCTAssertTrue(host.envelopeFiles[0].contains("-errors-logs-"))
        host.releaseHeld(with: .status(200))
        await client.flush()
        XCTAssertEqual(host.envelopeFiles, [])
    }

    #if canImport(ObjectiveC)
    func testCaptureExceptionReportsAnNSException() async {
        let client = start()
        let exception = NSException(name: .invalidArgumentException, reason: "bad index", userInfo: nil)
        client.captureException(exception)
        client.captureException(exception)
        await client.flush()
        XCTAssertEqual(host.errors.count, 1)
        XCTAssertEqual(host.errors[0].attribute("exception.type"), "NSInvalidArgumentException")
        XCTAssertEqual(host.errors[0].attribute("exception.message"), "bad index")
        XCTAssertEqual(host.errors[0].severityText, "ERROR")
    }
    #endif
}
