import Foundation
#if canImport(Darwin)
import Darwin
import MachO
#endif

struct BinaryImage: Sendable, Equatable {
    let address: UInt64
    let uuid: String?
    let name: String
}

let mainExecutableName: String = {
    let path = Bundle.main.executableURL?.path ?? CommandLine.arguments.first ?? ""
    return URL(fileURLWithPath: path).lastPathComponent
}()

func frame(address: UInt64, images: [BinaryImage], main: String, symbol: String? = nil) -> NativeFrame {
    let image = images.filter { $0.address <= address }.max { $0.address < $1.address }
    let name = image?.name ?? "<unknown>"
    return NativeFrame(
        function: symbol ?? hex(address),
        image: name,
        inApp: name == main,
        instructionAddress: address,
        imageAddress: image?.address,
        imageUUID: image?.uuid
    )
}

#if canImport(Darwin)
// Reads only the mapped Mach-O header, so it is safe in the dyld image callback.
func imageUUIDBytes(header: UnsafeRawPointer) -> UnsafeRawPointer? {
    let magic = header.load(as: UInt32.self)
    let is64 = magic == MH_MAGIC_64
    guard is64 || magic == MH_MAGIC else { return nil }
    let count = header.load(fromByteOffset: 16, as: UInt32.self)
    var command = header + (is64 ? MemoryLayout<mach_header_64>.size : MemoryLayout<mach_header>.size)
    for _ in 0 ..< count {
        let load = command.load(as: load_command.self)
        if load.cmd == UInt32(LC_UUID) {
            return command + 8
        }
        command += Int(load.cmdsize)
    }
    return nil
}

func imageUUID(header: UnsafeRawPointer) -> String? {
    guard let uuid = imageUUIDBytes(header: header) else { return nil }
    let digits = (0 ..< 16).map { uuid.load(fromByteOffset: $0, as: UInt8.self) }
        .map { String($0, radix: 16, uppercase: true) }
        .map { $0.count == 1 ? "0" + $0 : $0 }
    return [0 ..< 4, 4 ..< 6, 6 ..< 8, 8 ..< 10, 10 ..< 16]
        .map { digits[$0].joined() }
        .joined(separator: "-")
}

func loadedImages() -> [BinaryImage] {
    (0 ..< _dyld_image_count()).compactMap { index in
        guard let header = _dyld_get_image_header(index), let path = _dyld_get_image_name(index) else { return nil }
        return BinaryImage(
            address: UInt64(UInt(bitPattern: header)),
            uuid: imageUUID(header: UnsafeRawPointer(header)),
            name: URL(fileURLWithPath: String(cString: path)).lastPathComponent
        )
    }
}
#endif

func liveFrames(_ addresses: [UInt64]) -> [NativeFrame] {
    #if canImport(Darwin)
    return addresses.map { address in
        var info = Dl_info()
        guard let pointer = UnsafeRawPointer(bitPattern: UInt(address)), dladdr(pointer, &info) != 0,
              let base = info.dli_fbase
        else { return frame(address: address, images: [], main: mainExecutableName) }
        let name = info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent } ?? "<unknown>"
        let uuid = imageUUID(header: UnsafeRawPointer(base))
        let image = BinaryImage(address: UInt64(UInt(bitPattern: base)), uuid: uuid, name: name)
        return frame(address: address, images: [image], main: mainExecutableName, symbol: info.dli_sname.map { String(cString: $0) })
    }
    #else
    return addresses.map { frame(address: $0, images: [], main: mainExecutableName) }
    #endif
}

private func isSDKFrame(_ frame: NativeFrame) -> Bool {
    frame.function.hasPrefix("$s9Unhandled") || frame.function.contains("callStackReturnAddresses")
}

func currentStack() -> [NativeFrame] {
    let frames = liveFrames(Thread.callStackReturnAddresses.map { $0.uint64Value })
    return Array(frames.drop(while: isSDKFrame))
}
