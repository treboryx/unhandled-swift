import Dispatch
import Foundation

enum DeviceClass: String, Sendable {
    case phone, tablet, tv, desktop, vision, unknown
}

struct DeviceInfo: Sendable, Equatable {
    let osName: String
    let osVersion: String
    let deviceClass: DeviceClass
}

struct AppIdentity: Sendable, Equatable {
    let bundleId: String
    let version: String
    let build: String

    var release: String { "\(bundleId)@\(version)+\(build)" }
}

enum AppState: Sendable {
    case active
    case background
}

struct HTTPRequest: Sendable {
    let url: String
    let headers: [(String, String)]
    let body: String
}

enum HTTPResult: Sendable, Equatable {
    case status(Int)
    case failure
}

protocol Cancellable: Sendable {
    func cancel()
}

struct NativeCrashHandlers: Sendable {
    let uninstall: @Sendable () -> Void
}

// Everything the client reads from the platform, so the core runs and is tested on Linux.
protocol PlatformHost: Sendable {
    func wallNow() -> Double
    func monotonicNow() -> Double
    func random() -> Double
    func device() -> DeviceInfo
    func identity() -> AppIdentity?
    func startupTime() -> Double?
    func storageDirectory(serviceId: String) -> URL
    func send(_ request: HTTPRequest, completion: @escaping @Sendable (HTTPResult) -> Void)
    func schedule(after milliseconds: Double, on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void)
        -> any Cancellable
    func nextFrame(_ callback: @escaping @Sendable () -> Void)
    func onAppState(_ listener: @escaping @Sendable (AppState) -> Void) -> @Sendable () -> Void
    func installCrashHandlers(directory: URL, onException: @escaping @Sendable (UncaughtException) -> Void)
        -> NativeCrashHandlers?
}

struct UncaughtException: @unchecked Sendable {
    let object: AnyObject
    let type: String
    let message: String
    let frames: [NativeFrame]
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data("Unhandled: \(message)\n".utf8))
}
