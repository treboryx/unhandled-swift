import Foundation
@testable import Unhandled
import XCTest

final class CrashScratchTests: XCTestCase {
    private var scratch: UnsafeMutablePointer<CrashScratch>!
    private var names: [UnsafeMutablePointer<CChar>] = []

    override func setUp() {
        scratch = CrashScratch.allocate()
    }

    override func tearDown() {
        names.forEach { free($0) }
        names = []
    }

    private func text(_ length: Int) -> String {
        String(decoding: UnsafeBufferPointer(start: scratch.pointee.text, count: length), as: UTF8.self)
    }

    private func addImage(_ path: String, address: UInt64, uuid: (high: UInt64, low: UInt64)?) {
        let name = strdup(path)!
        names.append(name)
        scratch.pointee.images[scratch.pointee.imageCount] = CrashImage(name: name, address: address, uuid: uuid)
        scratch.pointee.imageCount += 1
    }

    private func allImageLines() -> String {
        var next = 0
        var lines = ""
        while next < scratch.pointee.imageCount {
            let length = formatImageLines(scratch, from: &next)
            XCTAssertLessThanOrEqual(length, CrashScratch.textCapacity)
            lines += text(length)
        }
        return lines
    }

    func testAllocationPreparesEverythingTheHandlerReads() {
        XCTAssertEqual(scratch.pointee.fd, -1, "no report file until install opens one")
        XCTAssertEqual(scratch.pointee.exceptionReported, 0)
        XCTAssertEqual(scratch.pointee.imageCount, 0)
        XCTAssertEqual(scratch.pointee.imagesDropped, 0)
        XCTAssertGreaterThan(CrashScratch.signalCapacity, Int(SIGTRAP))
        XCTAssertGreaterThan(CrashScratch.signalCapacity, Int(SIGSEGV))
        XCTAssertEqual(scratch.pointee.previousActions[CrashScratch.signalCapacity - 1].sa_flags, 0)
        XCTAssertNil(scratch.pointee.frames[CrashScratch.frameCapacity - 1])
        XCTAssertEqual(scratch.pointee.text[CrashScratch.textCapacity - 1], 0)
        XCTAssertNil(scratch.pointee.images[CrashScratch.imageCapacity - 1].name)
    }

    func testTheReportHasTheSignalTimeProgramCounterAndStack() {
        scratch.pointee.frames[0] = UnsafeMutableRawPointer(bitPattern: 0x1_0000_9000)
        scratch.pointee.frames[1] = UnsafeMutableRawPointer(bitPattern: 0x1_c000_0100)
        scratch.pointee.frames[2] = nil
        let length = formatCrashReport(scratch, signal: 11, time: 1_761_799_990, pc: 0x1_a000_1234, frameCount: 3)
        XCTAssertEqual(text(length), """
        signal 11
        time 1761799990
        pc 0x00000001a0001234
        0x0000000100009000
        0x00000001c0000100
        0x0000000000000000

        """)
    }

    func testTheReportWithoutAProgramCounterButWithDroppedImages() {
        scratch.pointee.imagesDropped = 3
        let length = formatCrashReport(scratch, signal: 6, time: 0, pc: nil, frameCount: 0)
        XCTAssertEqual(text(length), "signal 6\ntime 0\nimages_dropped 3\n")
    }

    func testAFullStackFitsTheTextBuffer() {
        for index in 0 ..< CrashScratch.frameCapacity {
            scratch.pointee.frames[index] = UnsafeMutableRawPointer(bitPattern: UInt.max - UInt(index))
        }
        scratch.pointee.imagesDropped = Int.max
        let length = formatCrashReport(
            scratch, signal: 11, time: Int(Int32.max), pc: UInt.max, frameCount: CrashScratch.frameCapacity + 10
        )
        let report = text(length)
        XCTAssertTrue(report.hasSuffix("0xffffffffffffff80\n"))
        XCTAssertEqual(report.split(separator: "\n").filter { $0.hasPrefix("0x") }.count, CrashScratch.frameCapacity)
    }

    func testImageLinesUseTheFileNameAndSkipUnloadedImages() {
        addImage("/usr/lib/system/libsystem_kernel.dylib", address: 0x1_a000_0000, uuid: (0x9F1C_2A44_1B7E_4C55, 0xA3D8_6E0F_2B1C_9A77))
        addImage("/gone.dylib", address: 0x1_d000_0000, uuid: nil)
        scratch.pointee.images[1].name = nil
        addImage("UIKitCore", address: 0x1_b000_0000, uuid: nil)
        XCTAssertEqual(allImageLines(), """
        image 0x00000001a0000000 9F1C2A44-1B7E-4C55-A3D8-6E0F2B1C9A77 libsystem_kernel.dylib
        image 0x00000001b0000000 - UIKitCore

        """)
    }

    func testEveryImageIsWrittenInWholeLinesAndParses() {
        let longName = String(repeating: "n", count: 400)
        for index in 0 ..< CrashScratch.imageCapacity {
            addImage("/Frameworks/\(index)-\(longName)", address: UInt64(index) << 32, uuid: (UInt64(index), 1))
        }
        let parsed = parseImages(allImageLines()).images
        XCTAssertEqual(parsed.count, CrashScratch.imageCapacity)
        XCTAssertEqual(parsed.last?.address, UInt64(CrashScratch.imageCapacity - 1) << 32)
        XCTAssertEqual(parsed.last?.uuid, "00000000-0000-03FF-0000-000000000001")
        XCTAssertEqual(parsed.last?.name.utf8.count, CrashScratch.imageNameCapacity)
    }
}
