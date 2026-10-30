import Dispatch
import Foundation
@testable import Unhandled
import XCTest

let serviceId = "0b4f6c2e-8a1d-4c3e-9f7a-1234567890ab"
let testDsn = "https://uh_live_7Hq2xR9vLp3sKd8mWn4tYb6c@ingest.example.com/\(serviceId)"
let fixedNow = 1_761_800_000_000.0

final class FakeTimer: Cancellable, @unchecked Sendable {
    let delay: Double
    private let work: @Sendable () -> Void
    private let queue: DispatchQueue
    private let state = Locked(false)

    init(delay: Double, queue: DispatchQueue, work: @escaping @Sendable () -> Void) {
        self.delay = delay
        self.queue = queue
        self.work = work
    }

    var isCancelled: Bool { state.withLock { $0 } }

    func cancel() {
        state.withLock { $0 = true }
    }

    func fire() {
        guard !isCancelled else { return }
        cancel()
        queue.sync(execute: work)
    }
}

struct SentRequest {
    let url: String
    let headers: [String: String]
    let body: String
}

final class FakeHost: PlatformHost, @unchecked Sendable {
    private struct State {
        var now = fixedNow
        var monotonic = 50_000.0
        var randomValue = 0.25
        var responses: [HTTPResult] = []
        var offline = false
        var holdSends = false
        var held: [@Sendable (HTTPResult) -> Void] = []
        var sent: [SentRequest] = []
        var timers: [FakeTimer] = []
        var listeners: [Int: @Sendable (AppState) -> Void] = [:]
        var startup: Double?
        var crashInstalls = 0
        var crashUninstalls = 0
        var frames: [@Sendable () -> Void] = []
        var deferFrames = false
    }

    let directory: URL
    private let state = Locked(State())

    init(directory: URL = FakeHost.temporaryDirectory()) {
        self.directory = directory
    }

    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("unhandled-tests")
            .appendingPathComponent(UUID().uuidString)
    }

    var now: Double {
        get { state.withLock { $0.now } }
        set { state.withLock { $0.now = newValue } }
    }

    var monotonic: Double {
        get { state.withLock { $0.monotonic } }
        set { state.withLock { $0.monotonic = newValue } }
    }

    var randomValue: Double {
        get { state.withLock { $0.randomValue } }
        set { state.withLock { $0.randomValue = newValue } }
    }

    var startup: Double? {
        get { state.withLock { $0.startup } }
        set { state.withLock { $0.startup = newValue } }
    }

    var offline: Bool {
        get { state.withLock { $0.offline } }
        set { state.withLock { $0.offline = newValue } }
    }

    var holdSends: Bool {
        get { state.withLock { $0.holdSends } }
        set { state.withLock { $0.holdSends = newValue } }
    }

    var deferFrames: Bool {
        get { state.withLock { $0.deferFrames } }
        set { state.withLock { $0.deferFrames = newValue } }
    }

    var sent: [SentRequest] { state.withLock { $0.sent } }
    var timers: [FakeTimer] { state.withLock { $0.timers } }
    var crashInstalls: Int { state.withLock { $0.crashInstalls } }
    var crashUninstalls: Int { state.withLock { $0.crashUninstalls } }

    func respond(with results: HTTPResult...) {
        state.withLock { $0.responses += results }
    }

    func releaseHeld(with result: HTTPResult) {
        let held = state.withLock { state in
            state.holdSends = false
            defer { state.held = [] }
            return state.held
        }
        held.forEach { $0(result) }
    }

    func clearSent() {
        state.withLock { $0.sent = [] }
    }

    func runFrames() {
        let frames = state.withLock { state in
            defer { state.frames = [] }
            return state.frames
        }
        frames.forEach { $0() }
    }

    func appState(_ appState: AppState) {
        let listeners = state.withLock { Array($0.listeners.values) }
        listeners.forEach { $0(appState) }
    }

    var envelopeFiles: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted()
    }

    func wallNow() -> Double { now }

    func monotonicNow() -> Double { monotonic }

    func random() -> Double { randomValue }

    func device() -> DeviceInfo {
        DeviceInfo(osName: "iOS", osVersion: "19.1", deviceClass: .phone)
    }

    func identity() -> AppIdentity? {
        AppIdentity(bundleId: "com.example.app", version: "1.4.0", build: "42")
    }

    func startupTime() -> Double? { startup }

    func storageDirectory(serviceId _: String) -> URL { directory }

    func send(_ request: HTTPRequest, completion: @escaping @Sendable (HTTPResult) -> Void) {
        let headers = Dictionary(request.headers, uniquingKeysWith: { _, last in last })
        let result = state.withLock { state -> HTTPResult? in
            state.sent.append(SentRequest(url: request.url, headers: headers, body: request.body))
            if state.holdSends {
                state.held.append(completion)
                return nil
            }
            if !state.responses.isEmpty { return state.responses.removeFirst() }
            return state.offline ? .failure : .status(200)
        }
        if let result { completion(result) }
    }

    func schedule(after milliseconds: Double, on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void)
        -> any Cancellable
    {
        let timer = FakeTimer(delay: milliseconds, queue: queue, work: work)
        state.withLock { $0.timers.append(timer) }
        return timer
    }

    func nextFrame(_ callback: @escaping @Sendable () -> Void) {
        let run = state.withLock { state -> Bool in
            if state.deferFrames { state.frames.append(callback) }
            return !state.deferFrames
        }
        if run { callback() }
    }

    func onAppState(_ listener: @escaping @Sendable (AppState) -> Void) -> @Sendable () -> Void {
        let id = state.withLock { state -> Int in
            let id = state.listeners.count
            state.listeners[id] = listener
            return id
        }
        return { [weak self] in self?.state.withLock { _ = $0.listeners.removeValue(forKey: id) } }
    }

    func installCrashHandlers(
        directory _: URL,
        onException _: @escaping @Sendable (UncaughtException) -> Void
    ) -> NativeCrashHandlers? {
        state.withLock { $0.crashInstalls += 1 }
        return NativeCrashHandlers { [weak self] in self?.state.withLock { $0.crashUninstalls += 1 } }
    }
}

indirect enum Value: Decodable, Equatable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral, ExpressibleByDictionaryLiteral
{
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case map([String: Value])

    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int64) { self = .int(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(floatLiteral value: Double) { self = .double(value) }
    init(dictionaryLiteral elements: (String, Value)...) {
        self = .map(Dictionary(uniqueKeysWithValues: elements))
    }

    private enum Keys: String, CodingKey {
        case stringValue, intValue, doubleValue, boolValue, kvlistValue
    }

    private struct KeyValueList: Decodable {
        let values: [KeyValue]
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if let text = try container.decodeIfPresent(String.self, forKey: .stringValue) {
            self = .string(text)
        } else if let text = try container.decodeIfPresent(String.self, forKey: .intValue) {
            guard let number = Int64(text) else {
                throw DecodingError.dataCorruptedError(forKey: .intValue, in: container, debugDescription: text)
            }
            self = .int(number)
        } else if let number = try container.decodeIfPresent(Double.self, forKey: .doubleValue) {
            self = .double(number)
        } else if let flag = try container.decodeIfPresent(Bool.self, forKey: .boolValue) {
            self = .bool(flag)
        } else {
            let list = try container.decode(KeyValueList.self, forKey: .kvlistValue)
            self = .map(Dictionary(list.values.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last }))
        }
    }

    var text: String? {
        if case let .string(text) = self { return text }
        return nil
    }
}

struct KeyValue: Decodable, Equatable {
    let key: String
    let value: Value
}

extension [KeyValue] {
    var dictionary: [String: Value] {
        Dictionary(map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
    }
}

struct Scope: Decodable, Equatable {
    let name: String
    let version: String
}

struct LogRecord: Decodable {
    let timeUnixNano: String
    let observedTimeUnixNano: String
    let severityNumber: Int
    let severityText: String
    let body: Value
    let attributes: [KeyValue]
    var scope = ""
    var resource: [String: Value] = [:]

    private enum CodingKeys: String, CodingKey {
        case timeUnixNano, observedTimeUnixNano, severityNumber, severityText, body, attributes
    }

    var attributeMap: [String: Value] { attributes.dictionary }

    func attribute(_ key: String) -> String? { attributeMap[key]?.text }
}

struct Span: Decodable {
    struct Status: Decodable, Equatable {
        let code: Int
    }

    let traceId: String
    let spanId: String
    let name: String
    let kind: Int
    let flags: Int
    let startTimeUnixNano: String
    let endTimeUnixNano: String
    let attributes: [KeyValue]
    let status: Status

    var attributeMap: [String: Value] { attributes.dictionary }
}

private struct LogsBody: Decodable {
    struct ResourceLogs: Decodable {
        struct Resource: Decodable { let attributes: [KeyValue] }
        struct ScopeLogs: Decodable {
            let scope: Scope
            let logRecords: [LogRecord]
        }

        let resource: Resource
        let scopeLogs: [ScopeLogs]
    }

    let resourceLogs: [ResourceLogs]
}

private struct TracesBody: Decodable {
    struct ResourceSpans: Decodable {
        struct ScopeSpans: Decodable {
            let scope: Scope
            let spans: [Span]
        }

        let scopeSpans: [ScopeSpans]
    }

    let resourceSpans: [ResourceSpans]
}

extension FakeHost {
    var logs: [LogRecord] {
        sent.filter { $0.url.hasSuffix("/v1/logs") }.flatMap { request -> [LogRecord] in
            guard let body = try? JSONDecoder().decode(LogsBody.self, from: Data(request.body.utf8)) else {
                XCTFail("undecodable logs body: \(request.body)")
                return []
            }
            return body.resourceLogs.flatMap { resourceLogs in
                resourceLogs.scopeLogs.flatMap { scopeLogs in
                    scopeLogs.logRecords.map { record in
                        var record = record
                        record.scope = scopeLogs.scope.name
                        record.resource = resourceLogs.resource.attributes.dictionary
                        return record
                    }
                }
            }
        }
    }

    var errors: [LogRecord] { logs.filter { $0.scope == "@unhandled/swift" } }

    var analytics: [LogRecord] { logs.filter { $0.scope == "unhandled.analytics" } }

    var spans: [Span] {
        sent.filter { $0.url.hasSuffix("/v1/traces") }.flatMap { request -> [Span] in
            guard let body = try? JSONDecoder().decode(TracesBody.self, from: Data(request.body.utf8)) else {
                XCTFail("undecodable traces body: \(request.body)")
                return []
            }
            return body.resourceSpans.flatMap { $0.scopeSpans.flatMap(\.spans) }
        }
    }
}

func jsonObject(_ text: String?) -> Any? {
    text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
}

class SDKTestCase: XCTestCase {
    var host = FakeHost()

    override func setUp() async throws {
        host = FakeHost()
    }

    override func tearDown() async throws {
        await Unhandled.shared.shutdown()
    }

    @discardableResult
    func start(
        _ host: FakeHost? = nil,
        dsn: String = testDsn,
        configure: (inout Options) -> Void = { _ in }
    ) -> Unhandled {
        let host = host ?? self.host
        var options = Options(dsn: dsn, environment: .production, storageDirectory: host.directory)
        configure(&options)
        return Unhandled.start(options, host: host)
    }
}
