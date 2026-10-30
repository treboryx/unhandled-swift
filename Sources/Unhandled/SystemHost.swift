import Dispatch
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#endif
#if canImport(QuartzCore) && (os(iOS) || os(tvOS) || os(visionOS))
import QuartzCore
#endif

private final class TimerHandle: Cancellable, @unchecked Sendable {
    let source: DispatchSourceTimer

    init(_ source: DispatchSourceTimer) {
        self.source = source
    }

    func cancel() {
        source.cancel()
    }
}

#if canImport(QuartzCore) && (os(iOS) || os(tvOS) || os(visionOS))
private final class FrameWaiter: NSObject {
    private let callback: @Sendable () -> Void

    init(_ callback: @escaping @Sendable () -> Void) {
        self.callback = callback
    }

    @objc func tick(_ link: CADisplayLink) {
        link.invalidate()
        callback()
    }
}
#endif

struct SystemHost: PlatformHost {
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    func wallNow() -> Double {
        Date().timeIntervalSince1970 * 1000
    }

    func monotonicNow() -> Double {
        ProcessInfo.processInfo.systemUptime * 1000
    }

    func random() -> Double {
        Double.random(in: 0 ..< 1)
    }

    func device() -> DeviceInfo {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(version.majorVersion).\(version.minorVersion)"
            + (version.patchVersion == 0 ? "" : ".\(version.patchVersion)")
        #if os(macOS)
        return DeviceInfo(osName: "macOS", osVersion: osVersion, deviceClass: .desktop)
        #elseif os(iOS)
        if ProcessInfo.processInfo.isiOSAppOnMac || ProcessInfo.processInfo.isMacCatalystApp {
            return DeviceInfo(osName: "macOS", osVersion: osVersion, deviceClass: .desktop)
        }
        let tablet = SystemHost.machine().hasPrefix("iPad")
        return DeviceInfo(osName: tablet ? "iPadOS" : "iOS", osVersion: osVersion, deviceClass: tablet ? .tablet : .phone)
        #elseif os(tvOS)
        return DeviceInfo(osName: "tvOS", osVersion: osVersion, deviceClass: .tv)
        #elseif os(visionOS)
        return DeviceInfo(osName: "visionOS", osVersion: osVersion, deviceClass: .vision)
        #elseif os(watchOS)
        return DeviceInfo(osName: "watchOS", osVersion: osVersion, deviceClass: .unknown)
        #elseif os(Linux)
        return DeviceInfo(osName: "Linux", osVersion: osVersion, deviceClass: .unknown)
        #else
        return DeviceInfo(osName: "unknown", osVersion: osVersion, deviceClass: .unknown)
        #endif
    }

    #if os(iOS)
    // The model family is read only to tell a phone from a tablet; the model itself is never sent.
    private static func machine() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &bytes, &size, nil, 0)
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    #endif

    func identity() -> AppIdentity? {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let bundleId = Bundle.main.bundleIdentifier,
              let version = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String
        else { return nil }
        return AppIdentity(bundleId: bundleId, version: version, build: build)
    }

    func startupTime() -> Double? {
        #if canImport(Darwin)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_starttime
        let startWall = Double(start.tv_sec) * 1000 + Double(start.tv_usec) / 1000
        return monotonicNow() - (wallNow() - startWall)
        #else
        return nil
        #endif
    }

    func storageDirectory(serviceId: String) -> URL {
        #if canImport(Darwin)
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        #else
        let base = FileManager.default.temporaryDirectory
        #endif
        return base.appendingPathComponent("unhandled").appendingPathComponent(serviceId)
    }

    func send(_ request: HTTPRequest, completion: @escaping @Sendable (HTTPResult) -> Void) {
        guard let url = URL(string: request.url) else {
            completion(.status(400))
            return
        }
        var urlRequest = URLRequest(url: url, timeoutInterval: 10)
        urlRequest.httpMethod = "POST"
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.httpBody = Data(request.body.utf8)
        session.dataTask(with: urlRequest) { _, response, error in
            if error == nil, let http = response as? HTTPURLResponse {
                completion(.status(http.statusCode))
            } else {
                completion(.failure)
            }
        }.resume()
    }

    func schedule(after milliseconds: Double, on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void)
        -> any Cancellable
    {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .milliseconds(Int(milliseconds.rounded())))
        source.setEventHandler {
            source.cancel()
            work()
        }
        source.resume()
        return TimerHandle(source)
    }

    func nextFrame(_ callback: @escaping @Sendable () -> Void) {
        #if canImport(QuartzCore) && (os(iOS) || os(tvOS) || os(visionOS))
        DispatchQueue.main.async {
            let link = CADisplayLink(target: FrameWaiter(callback), selector: #selector(FrameWaiter.tick(_:)))
            link.add(to: .main, forMode: .common)
        }
        #else
        DispatchQueue.global().async(execute: callback)
        #endif
    }

    func onAppState(_ listener: @escaping @Sendable (AppState) -> Void) -> @Sendable () -> Void {
        #if os(iOS) || os(tvOS) || os(visionOS)
        let names: [(String, AppState)] = [
            ("UIApplicationDidEnterBackgroundNotification", .background),
            ("UIApplicationWillEnterForegroundNotification", .active),
        ]
        #elseif os(watchOS)
        let names: [(String, AppState)] = [
            ("WKApplicationDidEnterBackgroundNotification", .background),
            ("WKApplicationWillEnterForegroundNotification", .active),
        ]
        #elseif os(macOS)
        let names: [(String, AppState)] = [("NSApplicationWillTerminateNotification", .background)]
        #else
        let names: [(String, AppState)] = []
        #endif
        let center = NotificationCenter.default
        let observers = names.map { name, state in
            center.addObserver(forName: Notification.Name(name), object: nil, queue: nil) { _ in listener(state) }
        }
        let tokens = Locked(observers)
        return {
            tokens.withLock { observers in
                observers.forEach(NotificationCenter.default.removeObserver)
                observers = []
            }
        }
    }

    func installCrashHandlers(
        directory: URL,
        onException: @escaping @Sendable (UncaughtException) -> Void
    ) -> NativeCrashHandlers? {
        #if canImport(Darwin)
        return CrashCapture.install(directory: directory, onException: onException)
        #else
        return nil
        #endif
    }
}
