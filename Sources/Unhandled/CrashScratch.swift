#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct CrashImage {
    var name: UnsafePointer<CChar>?
    var address: UInt64
    var uuid: (high: UInt64, low: UInt64)?
}

// Everything the signal handler reads or writes. It is allocated before any crash, so the handler never allocates.
struct CrashScratch {
    static let frameCapacity = 128
    static let textCapacity = 4096
    static let signalCapacity = 32
    static let imageCapacity = 1024
    static let imageNameCapacity = 255

    var fd: Int32 = -1
    var exceptionReported: Int32 = 0
    let frames: UnsafeMutablePointer<UnsafeMutableRawPointer?>
    let text: UnsafeMutablePointer<UInt8>
    let previousActions: UnsafeMutablePointer<sigaction>
    let images: UnsafeMutablePointer<CrashImage>
    var imageCount = 0
    var imagesDropped = 0

    static func allocate() -> UnsafeMutablePointer<CrashScratch> {
        let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: frameCapacity)
        frames.initialize(repeating: nil, count: frameCapacity)
        let text = UnsafeMutablePointer<UInt8>.allocate(capacity: textCapacity)
        text.initialize(repeating: 0, count: textCapacity)
        let previousActions = UnsafeMutablePointer<sigaction>.allocate(capacity: signalCapacity)
        previousActions.initialize(repeating: sigaction(), count: signalCapacity)
        let images = UnsafeMutablePointer<CrashImage>.allocate(capacity: imageCapacity)
        images.initialize(repeating: CrashImage(name: nil, address: 0, uuid: nil), count: imageCapacity)
        let scratch = UnsafeMutablePointer<CrashScratch>.allocate(capacity: 1)
        scratch.initialize(to: CrashScratch(frames: frames, text: text, previousActions: previousActions, images: images))
        return scratch
    }
}

private struct TextWriter {
    let base: UnsafeMutablePointer<UInt8>
    var length = 0

    var remaining: Int { CrashScratch.textCapacity - length }

    mutating func byte(_ value: UInt8) {
        if length < CrashScratch.textCapacity {
            base[length] = value
            length += 1
        }
    }

    mutating func text(_ value: StaticString) {
        for index in 0 ..< value.utf8CodeUnitCount {
            byte(value.utf8Start[index])
        }
    }

    mutating func decimal(_ value: Int) {
        var divisor = 1
        while value / divisor >= 10 { divisor *= 10 }
        while divisor > 0 {
            byte(UInt8(48 + (value / divisor) % 10))
            divisor /= 10
        }
    }

    mutating func hexDigits(_ value: UInt64, count: Int, uppercase: Bool) {
        var shift = (count - 1) * 4
        while shift >= 0 {
            let digit = UInt8((value >> UInt64(shift)) & 0xF)
            byte(digit < 10 ? 48 + digit : (uppercase ? 55 : 87) + digit)
            shift -= 4
        }
    }

    mutating func address(_ value: UInt64) {
        text("0x")
        hexDigits(value, count: 16, uppercase: false)
    }

    mutating func uuid(_ value: (high: UInt64, low: UInt64)) {
        hexDigits(value.high >> 32, count: 8, uppercase: true)
        byte(45)
        hexDigits(value.high >> 16, count: 4, uppercase: true)
        byte(45)
        hexDigits(value.high, count: 4, uppercase: true)
        byte(45)
        hexDigits(value.low >> 48, count: 4, uppercase: true)
        byte(45)
        hexDigits(value.low, count: 12, uppercase: true)
    }

    mutating func basename(_ path: UnsafePointer<CChar>) {
        var start = 0
        var end = 0
        while path[end] != 0 {
            if path[end] == 47 { start = end + 1 }
            end += 1
        }
        for index in start ..< min(end, start + CrashScratch.imageNameCapacity) {
            byte(UInt8(bitPattern: path[index]))
        }
    }
}

// Runs inside the signal handler: it reads and writes only the scratch, and returns the report's length in `text`.
func formatCrashReport(
    _ scratch: UnsafeMutablePointer<CrashScratch>,
    signal: Int32,
    time: Int,
    pc: UInt?,
    frameCount: Int
) -> Int {
    var writer = TextWriter(base: scratch.pointee.text)
    writer.text("signal ")
    writer.decimal(Int(signal))
    writer.text("\ntime ")
    writer.decimal(time)
    writer.byte(10)
    if let pc {
        writer.text("pc ")
        writer.address(UInt64(pc))
        writer.byte(10)
    }
    if scratch.pointee.imagesDropped > 0 {
        writer.text("images_dropped ")
        writer.decimal(scratch.pointee.imagesDropped)
        writer.byte(10)
    }
    for index in 0 ..< min(frameCount, CrashScratch.frameCapacity) {
        writer.address(UInt64(UInt(bitPattern: scratch.pointee.frames[index])))
        writer.byte(10)
    }
    return writer.length
}

// Runs inside the signal handler: fills `text` with whole image lines from `next` on, and returns their length.
func formatImageLines(_ scratch: UnsafeMutablePointer<CrashScratch>, from next: inout Int) -> Int {
    let longestLine = 6 + 18 + 1 + 36 + 1 + CrashScratch.imageNameCapacity + 1
    var writer = TextWriter(base: scratch.pointee.text)
    let count = min(scratch.pointee.imageCount, CrashScratch.imageCapacity)
    while next < count, writer.remaining >= longestLine {
        let image = scratch.pointee.images[next]
        next += 1
        guard let name = image.name else { continue }
        writer.text("image ")
        writer.address(image.address)
        writer.byte(32)
        if let uuid = image.uuid {
            writer.uuid(uuid)
        } else {
            writer.byte(45)
        }
        writer.byte(32)
        writer.basename(name)
        writer.byte(10)
    }
    return writer.length
}
