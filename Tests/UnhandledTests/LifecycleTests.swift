import Foundation
@testable import Unhandled
import XCTest

final class LifecycleTests: SDKTestCase {
    private func sentSpans() async -> [Span] {
        await Unhandled.shared.flush()
        return host.spans
    }

    func testScreensEmitSpansAndTheFirstEndsTheColdStart() async {
        host.startup = host.monotonic - 1500
        host.deferFrames = true
        let client = start()
        client.trackScreen("Home")
        host.now += 40
        host.runFrames()
        host.runFrames()
        client.trackScreen("Home")
        client.trackScreen("Settings")
        host.now += 20
        host.runFrames()

        let spans = await sentSpans()
        XCTAssertEqual(spans.map(\.name), ["Home", "app start", "Settings"])
        let home = spans[0]
        XCTAssertEqual(home.attributeMap, ["app.screen.name": "Home"])
        XCTAssertEqual(home.startTimeUnixNano, "1761800000000000000")
        XCTAssertEqual(home.endTimeUnixNano, "1761800000040000000")
        XCTAssertEqual(home.kind, 1)
        XCTAssertEqual(home.flags, 256)
        XCTAssertEqual(home.status, .init(code: 0))
        XCTAssertEqual(home.traceId.count, 32)
        XCTAssertEqual(home.spanId.count, 16)

        let appStart = spans[1]
        XCTAssertEqual(appStart.attributeMap, ["app.start.type": "cold", "app.screen.name": "Home"])
        XCTAssertEqual(appStart.endTimeUnixNano, "1761800000040000000")
        XCTAssertEqual(appStart.startTimeUnixNano, "1761799998540000000")

        XCTAssertEqual(spans[2].attributeMap, ["app.screen.name": "Settings", "app.screen.previous": "Home"])
    }

    func testAppReadyEndsTheColdStartOnce() async {
        host.startup = host.monotonic - 800
        let client = start()
        client.appReady()
        client.appReady()
        client.trackScreen("Home")
        let spans = await sentSpans()
        XCTAssertEqual(spans.filter { $0.name == "app start" }.count, 1)
    }

    func testColdStartIsSkippedWhenImplausible() async {
        host.startup = host.monotonic - 61000
        let client = start()
        client.appReady()
        host.startup = nil
        let spans = await sentSpans()
        XCTAssertEqual(spans.count, 0)
        await client.shutdown()

        let unknown = FakeHost()
        let second = start(unknown)
        second.appReady()
        await second.flush()
        XCTAssertEqual(unknown.spans.count, 0)
    }

    func testBackgroundPersistsAndForegroundEmitsAResumeSpan() async {
        host.holdSends = true
        let client = start()
        client.track("before background")
        host.appState(.background)
        XCTAssertEqual(host.envelopeFiles.count, 1, "background writes the buffer to disk")
        host.releaseHeld(with: .status(200))
        host.appState(.active)
        let spans = await sentSpans()
        XCTAssertEqual(spans.map(\.name), ["app resume"])
        XCTAssertEqual(spans[0].attributeMap, ["app.start.type": "resume"])
    }

    func testForegroundWithoutBackgroundEmitsNothing() async {
        let client = start()
        host.appState(.active)
        _ = client
        let spans = await sentSpans()
        XCTAssertEqual(spans.count, 0)
    }

    func testTracesSampleRateDropsSpans() async {
        host.randomValue = 0.5
        let client = start { $0.tracesSampleRate = 0.25 }
        client.trackScreen("Home")
        let spans = await sentSpans()
        XCTAssertEqual(spans.count, 0)
    }

    func testShutdownStopsSendingAndRemovesTheLifecycleListener() async {
        let client = start()
        await client.shutdown()
        client.track("after")
        client.captureMessage("after")
        host.appState(.background)
        host.appState(.active)
        await client.flush()
        XCTAssertEqual(host.sent.count, 0)
        XCTAssertEqual(host.envelopeFiles, [])
    }
}

final class CrashFileTests: SDKTestCase {
    private let imageLines = """
    image 0x0000000100000000 4C4C44D3-5555-3144-A1B2-C3D4E5F60718 Aisle
    image 0x00000001a0000000 9F1C2A44-1B7E-4C55-A3D8-6E0F2B1C9A77 libsystem_kernel.dylib
    image 0x00000001b0000000 - UIKitCore
    image 0x00000001c0000000 7D2E1C55-0A4B-4E1F-9C3D-2B6A8F0E1D44 libsystem_platform.dylib

    """

    private let reportHeader = """
    signal 11
    time 1761799990
    pc 0x00000001a0001234
    0x0000000100009000
    0x00000001c0000100
    0x0000000100004f10
    0x00000001b0002000
    0x0000000000000010

    """

    private let expectedFrames = #"[{"filename":"libsystem_kernel.dylib","function":"0x00000001a0001234","lineno":0,"colno":0,"in_app":false,"instruction_addr":"0x00000001a0001234","image_addr":"0x00000001a0000000","image_uuid":"9F1C2A44-1B7E-4C55-A3D8-6E0F2B1C9A77"},{"filename":"Aisle","function":"0x0000000100004f10","lineno":0,"colno":0,"in_app":true,"instruction_addr":"0x0000000100004f10","image_addr":"0x0000000100000000","image_uuid":"4C4C44D3-5555-3144-A1B2-C3D4E5F60718"},{"filename":"UIKitCore","function":"0x00000001b0002000","lineno":0,"colno":0,"in_app":false,"instruction_addr":"0x00000001b0002000","image_addr":"0x00000001b0000000"},{"filename":"<unknown>","function":"0x0000000000000010","lineno":0,"colno":0,"in_app":false,"instruction_addr":"0x0000000000000010"}]"#

    private var crashDirectory: URL { host.directory.appendingPathComponent("crash") }

    private func writeFixture(report: String, images: String) throws {
        try FileManager.default.createDirectory(at: crashDirectory, withIntermediateDirectories: true)
        try Data(images.utf8).write(to: crashDirectory.appendingPathComponent("images.txt"))
        try Data(report.utf8).write(to: crashDirectory.appendingPathComponent("crash.txt"))
    }

    private func assertOneFatalSegv() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: crashDirectory.appendingPathComponent("crash.txt").path))
        XCTAssertEqual(host.errors.count, 1)
        let record = try XCTUnwrap(host.errors.first)
        XCTAssertEqual(record.severityText, "FATAL")
        XCTAssertEqual(record.timeUnixNano, "1761799990000000000")
        XCTAssertEqual(record.body, "Fatal signal SIGSEGV")
        XCTAssertEqual(record.attribute("exception.type"), "SIGSEGV")
        XCTAssertEqual(record.attribute("exception.message"), "Fatal signal SIGSEGV")
        XCTAssertEqual(record.attribute("unhandled.exception.frames"), expectedFrames)
        let values = try XCTUnwrap(jsonObject(record.attribute("unhandled.exception.values")) as? [[String: Any]])
        let mechanism = try XCTUnwrap(values.first?["mechanism"] as? [String: Any])
        XCTAssertEqual(mechanism["type"] as? String, "signal")
        XCTAssertEqual(mechanism["handled"] as? Bool, false)
        XCTAssertEqual(
            record.attribute("exception.stacktrace")?.split(separator: "\n").first.map(String.init),
            "0   libsystem_kernel.dylib           0x00000001a0001234 0x00000001a0001234"
        )
    }

    func testAPendingCrashFileBecomesAFatalSignalErrorWithTheImagesLoadedAtCrashTime() async throws {
        let staleAtStart = "main Aisle\nimage 0x0000000100000000 - Stale\n"
        try writeFixture(report: reportHeader + imageLines, images: staleAtStart)
        let client = start()
        await client.flush()
        try assertOneFatalSegv()
    }

    func testACrashFileWithoutImagesFallsBackToTheImagesFromStart() async throws {
        try writeFixture(report: reportHeader, images: "main Aisle\n" + imageLines)
        let client = start()
        await client.flush()
        try assertOneFatalSegv()
    }

    func testAnEmptyCrashFileMeansTheLastRunDidNotCrash() async throws {
        try writeFixture(report: "", images: "main Aisle\n" + imageLines)
        let client = start()
        await client.flush()
        XCTAssertEqual(host.errors.count, 0)
    }

    func testCaptureCrashesFalseLeavesThePendingFileAlone() async throws {
        try writeFixture(report: reportHeader + imageLines, images: "main Aisle\n")
        let client = start { $0.captureCrashes = false }
        await client.flush()
        XCTAssertEqual(host.errors.count, 0)
        let pending = try String(contentsOf: crashDirectory.appendingPathComponent("crash.txt"), encoding: .utf8)
        XCTAssertEqual(pending, reportHeader + imageLines)
    }
}
