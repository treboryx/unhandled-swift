import Foundation
@testable import Unhandled
import XCTest

final class TransportTests: SDKTestCase {
    func testTelemetryWaitsForTheBatchTimerThenSendsOneEnvelope() async {
        let client = start()
        client.track("one")
        client.track("two")
        XCTAssertEqual(host.envelopeFiles, [], "telemetry is buffered in memory")
        let batch = host.timers.filter { $0.delay == 1000 }
        XCTAssertEqual(batch.count, 1)
        batch[0].fire()
        await client.flush()
        XCTAssertEqual(host.sent.count, 1)
        XCTAssertEqual(host.analytics.count, 2)
    }

    func testAFullBatchPersistsWithoutTheTimerAndIsSent() async {
        host.holdSends = true
        let client = start()
        for index in 0 ..< 50 {
            client.track("event_\(index)")
        }
        await waitFor { self.host.envelopeFiles.count == 1 }
        XCTAssertTrue(host.envelopeFiles[0].contains("-telemetry-logs-"))
        host.releaseHeld(with: .status(200))
        await client.flush()
        let names = host.analytics.compactMap { record -> String? in
            guard case let .map(body) = record.body else { return nil }
            return body["name"]?.text
        }
        XCTAssertEqual(names, (0 ..< 50).map { "event_\($0)" })
        XCTAssertEqual(host.envelopeFiles, [])
    }

    func testBufferedBytesPersistAtThirtyThousand() async {
        host.holdSends = true
        let client = start()
        let large = String(repeating: "x", count: 250)
        for index in 0 ..< 12 {
            let properties = Dictionary(uniqueKeysWithValues: (0 ..< 10).map { ("k\($0)", AnalyticsValue.string(large)) })
            client.track("event_\(index)", properties: properties)
        }
        await waitFor { self.host.envelopeFiles.count == 1 }
        XCTAssertGreaterThanOrEqual(Int(host.envelopeFiles[0].split(separator: "-")[4].dropLast(5)) ?? 0, 30000)
        host.releaseHeld(with: .status(200))
        await client.flush()
    }

    func testRetryableFailuresBackOffExponentiallyUntilDelivered() async {
        host.respond(with: .status(503), .status(429), .failure, .status(408))
        let client = start()
        client.captureMessage("retry me")
        await waitFor { self.host.timers.count == 1 }
        for attempt in 2 ... 4 {
            host.timers.last?.fire()
            await waitFor { self.host.timers.count == attempt }
        }
        XCTAssertEqual(host.timers.map(\.delay), [1250, 2500, 5000, 10000])
        XCTAssertEqual(host.envelopeFiles.count, 1)

        host.timers.last?.fire()
        await waitFor { self.host.envelopeFiles.isEmpty }
        XCTAssertEqual(host.sent.count, 5)
        _ = client
    }

    func testFlushReturnsWhenASendFails() async {
        host.respond(with: .failure, .failure)
        let client = start()
        client.captureMessage("offline")
        await client.flush()
        XCTAssertEqual(host.envelopeFiles.count, 1)
    }

    func testForegroundResetsTheBackoff() async {
        host.respond(with: .status(500), .status(500))
        let client = start()
        client.captureMessage("retry me")
        await waitFor { self.host.timers.count == 1 }
        host.appState(.active)
        await waitFor { self.host.timers.count == 2 }
        XCTAssertEqual(host.timers.map(\.delay), [1250, 1250])
        XCTAssertTrue(host.timers[0].isCancelled)
        _ = client
    }

    func testBackoffFormula() {
        XCTAssertEqual(backoffDelay(failures: 1, random: 0), 1000)
        XCTAssertEqual(backoffDelay(failures: 1, random: 1), 2000)
        XCTAssertEqual(backoffDelay(failures: 3, random: 0.5), 6000)
        XCTAssertEqual(backoffDelay(failures: 20, random: 1), 300_000)
    }

    func testRejectedBatchIsDroppedAndTheNextOneStillSends() async {
        host.respond(with: .status(400))
        let client = start()
        client.captureMessage("rejected")
        client.captureMessage("accepted")
        await client.flush()
        XCTAssertEqual(host.envelopeFiles, [])
        XCTAssertEqual(host.sent.count, 2)
        XCTAssertTrue(host.timers.filter { $0.delay != 1000 }.isEmpty)
    }

    func testOfflineEventsSurviveARelaunchAndSendInOrder() async {
        host.offline = true
        let first = start()
        first.captureMessage("first")
        first.track("opened")
        await first.flush()
        XCTAssertEqual(host.envelopeFiles.count, 2)
        await first.shutdown()

        let relaunched = FakeHost(directory: host.directory)
        let second = start(relaunched)
        await second.flush()
        XCTAssertEqual(relaunched.sent.count, 2)
        XCTAssertEqual(relaunched.errors.first?.attribute("exception.message"), "first")
        XCTAssertEqual(relaunched.envelopeFiles, [])
    }

    func testQueueEvictsTelemetryBeforeErrorsAndRespectsBothCapsAcrossARestart() async throws {
        host.offline = true
        let first = start { $0.queueLimits = QueueLimits(maxBytes: 1_000_000, maxEnvelopes: 3) }
        first.captureMessage("error one")
        first.track("old")
        await first.flush()
        host.now += 1
        first.track("new")
        await first.flush()
        host.now += 1
        first.captureMessage("error two")
        await first.shutdown()
        let names = host.envelopeFiles
        XCTAssertEqual(names.map { $0.contains("-errors-") }, [true, false, true])

        try Data("junk".utf8).write(to: host.directory.appendingPathComponent("not-an-envelope.txt"))
        let relaunched = FakeHost(directory: host.directory)
        relaunched.offline = true
        let errorBytes = names.filter { $0.contains("-errors-") }.compactMap { Int($0.split(separator: "-")[4].dropLast(5)) }
        let second = start(relaunched) { $0.queueLimits = QueueLimits(maxBytes: errorBytes.reduce(0, +), maxEnvelopes: 10) }
        XCTAssertEqual(relaunched.envelopeFiles, names.filter { $0.contains("-errors-") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: host.directory.appendingPathComponent("not-an-envelope.txt").path))
        await second.shutdown()

        let third = FakeHost(directory: host.directory)
        third.offline = true
        start(third) { $0.queueLimits = QueueLimits(maxBytes: 1_000_000, maxEnvelopes: 1) }
        XCTAssertEqual(third.envelopeFiles, [names[2]], "with only errors left, the oldest error goes")
    }

    func testEnvelopeLargerThanTheBudgetIsDropped() async {
        host.holdSends = true
        let client = start { $0.queueLimits = QueueLimits(maxBytes: 100, maxEnvelopes: 10) }
        client.captureMessage("too big for a hundred bytes")
        XCTAssertEqual(host.envelopeFiles, [])
        host.releaseHeld(with: .status(200))
        _ = client
    }

    func testEnvelopeNamesFollowTheQueueFormat() async throws {
        host.holdSends = true
        let client = start()
        client.captureMessage("named")
        let name = try XCTUnwrap(host.envelopeFiles.first)
        let parts = name.split(separator: "-")
        XCTAssertEqual(String(parts[0]), "001761800000000")
        XCTAssertEqual(String(parts[1]), "000001")
        XCTAssertEqual(parts[2], "errors")
        XCTAssertEqual(parts[3], "logs")
        let size = try FileManager.default.attributesOfItem(atPath: host.directory.appendingPathComponent(name).path)[.size] as? Int
        XCTAssertEqual("\(size ?? -1).json", String(parts[4]))
        host.releaseHeld(with: .status(200))
        await client.flush()
    }

    private func waitFor(_ condition: @escaping () -> Bool) async {
        for _ in 0 ..< 200 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition())
    }
}
