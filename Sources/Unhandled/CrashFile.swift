import Foundation

enum CrashFiles {
    static let directoryName = "crash"
    static let report = "crash.txt"
    static let images = "images.txt"
}

struct NativeCrash: Equatable {
    let type: String
    let message: String
    let timeMilliseconds: Double?
    let frames: [NativeFrame]
}

// The report is written by the signal handler on an Apple device, so signal numbers are Darwin's.
private let signalNames: [Int: String] = [4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 8: "SIGFPE", 10: "SIGBUS", 11: "SIGSEGV"]

private func parseHex(_ text: Substring) -> UInt64? {
    text.hasPrefix("0x") ? UInt64(text.dropFirst(2), radix: 16) : nil
}

func parseImages(_ text: String) -> (main: String, images: [BinaryImage]) {
    var main = ""
    var images: [BinaryImage] = []
    for line in text.split(separator: "\n") {
        if line.hasPrefix("main ") {
            main = String(line.dropFirst(5))
            continue
        }
        let fields = line.split(separator: " ", maxSplits: 3)
        guard fields.count == 4, fields[0] == "image", let address = parseHex(fields[1]) else { continue }
        images.append(BinaryImage(address: address, uuid: fields[2] == "-" ? nil : String(fields[2]), name: String(fields[3])))
    }
    return (main, images)
}

func formatImages(main: String, images: [BinaryImage]) -> String {
    (["main \(main)"] + images.map { "image \(hex($0.address)) \($0.uuid ?? "-") \($0.name)" })
        .joined(separator: "\n") + "\n"
}

func parseCrash(report: String, images imageText: String) -> NativeCrash? {
    var signal: Int?
    var seconds: Double?
    var addresses: [UInt64] = []
    var pc: UInt64?
    for line in report.split(separator: "\n") {
        if line.hasPrefix("pc ") {
            pc = parseHex(line.dropFirst(3))
        } else if line.hasPrefix("signal ") {
            signal = Int(line.dropFirst(7))
        } else if line.hasPrefix("time ") {
            seconds = Double(line.dropFirst(5))
        } else if let address = parseHex(line) {
            addresses.append(address)
        }
    }
    guard let signal else { return nil }
    let name = signalNames[signal] ?? "SIGNAL \(signal)"
    // The handler writes the images loaded at crash time; the list from start is the fallback.
    let (main, installImages) = parseImages(imageText)
    let crashImages = parseImages(report).images
    let images = crashImages.isEmpty ? installImages : crashImages
    var frames = addresses.map { frame(address: $0, images: images, main: main) }
    // The handler's own frames end at _sigtramp; the crash site is the program counter it saved.
    if let trampoline = frames.prefix(4).firstIndex(where: { $0.image == "libsystem_platform.dylib" }) {
        frames.removeFirst(trampoline + 1)
    }
    if let pc {
        frames.insert(frame(address: pc, images: images, main: main), at: 0)
    }
    return NativeCrash(type: name, message: "Fatal signal \(name)", timeMilliseconds: seconds.map { $0 * 1000 }, frames: frames)
}

// Reads and removes what the previous run's signal handler left, so each crash is reported once.
func takePendingCrash(in directory: URL) -> NativeCrash? {
    let reportURL = directory.appendingPathComponent(CrashFiles.report)
    let imagesURL = directory.appendingPathComponent(CrashFiles.images)
    defer { try? FileManager.default.removeItem(at: reportURL) }
    guard let report = try? String(contentsOf: reportURL, encoding: .utf8), !report.isEmpty else { return nil }
    let images = (try? String(contentsOf: imagesURL, encoding: .utf8)) ?? ""
    return parseCrash(report: report, images: images)
}
