import Dispatch
import Foundation

enum TransportTuning {
    static let batchDelayMilliseconds = 1000.0
    static let batchRecords = 50
    static let batchBytes = 30_000
    static let backoffBaseMilliseconds = 2000.0
    static let backoffMaxMilliseconds = 300_000.0
}

func backoffDelay(failures: Int, random: Double) -> Double {
    let exponent = Double(max(0, failures - 1))
    return min(TransportTuning.backoffMaxMilliseconds, TransportTuning.backoffBaseMilliseconds * pow(2, exponent))
        * (0.5 + random / 2)
}

private enum Outcome {
    case delivered, rejected, retry

    init(_ result: HTTPResult) {
        switch result {
        case let .status(code) where (200 ..< 300).contains(code): self = .delivered
        case let .status(code) where code == 408 || code == 429 || code >= 500: self = .retry
        case .status: self = .rejected
        case .failure: self = .retry
        }
    }
}

final class Transport: Sendable {
    private struct PendingLog {
        let scope: String
        let json: String
    }

    private struct State {
        var logs: [PendingLog] = []
        var spans: [String] = []
        var bufferedBytes = 0
        var batchTimer: (any Cancellable)?
        var persistQueued = false
        var retryTimer: (any Cancellable)?
        var failures = 0
        var sending = false
        var rerun = false
        var stopped = false
        var rejectionWarned = false
        var drainWaiters: [@Sendable () -> Void] = []
    }

    private let state: Locked<State>
    // Disk writes hold only this lock, so a caller adding to the buffer never waits on one.
    private let queue: Locked<PersistentQueue>
    private let host: any PlatformHost
    private let endpoint: String
    private let headers: [(String, String)]
    private let resource: String
    private let work = DispatchQueue(label: "net.unhandled.transport")

    init(endpoint: String, headers: [(String, String)], resource: JSON, queue: PersistentQueue, host: any PlatformHost) {
        self.endpoint = endpoint
        self.headers = headers + [("content-type", "application/json")]
        self.resource = JSON.object([.init("attributes", resource)]).serialized
        self.host = host
        self.queue = Locked(queue)
        state = Locked(State())
    }

    private func logsBody(_ records: [PendingLog]) -> String {
        var scopes: [String] = []
        var byScope: [String: [String]] = [:]
        for record in records {
            if byScope[record.scope] == nil { scopes.append(record.scope) }
            byScope[record.scope, default: []].append(record.json)
        }
        let scopeLogs = scopes.map { name in
            let scope = JSON.object([.init("name", .string(name)), .init("version", .string(SDK.version))]).serialized
            return "{\"scope\":\(scope),\"logRecords\":[\(byScope[name]!.joined(separator: ","))]}"
        }
        return "{\"resourceLogs\":[{\"resource\":\(resource),\"scopeLogs\":[\(scopeLogs.joined(separator: ","))]}]}"
    }

    private func tracesBody(_ spans: [String]) -> String {
        let scope = JSON.object([.init("name", .string(SDK.name)), .init("version", .string(SDK.version))]).serialized
        return "{\"resourceSpans\":[{\"resource\":\(resource),\"scopeSpans\":[{\"scope\":\(scope),"
            + "\"spans\":[\(spans.joined(separator: ","))]}]}]}"
    }

    // Buffered records become files before anything is sent, so a kill between here and delivery loses nothing.
    // The queue lock is taken first, so a persist that finds the buffer empty still waits for one already writing.
    func persist() {
        queue.withLock { queue in
            let (logs, spans) = state.withLock { state in
                state.batchTimer?.cancel()
                state.batchTimer = nil
                state.persistQueued = false
                state.bufferedBytes = 0
                defer {
                    state.logs = []
                    state.spans = []
                }
                return (state.logs, state.spans)
            }
            let now = host.wallNow()
            if !logs.isEmpty {
                queue.enqueue(.telemetry, .logs, body: logsBody(logs), now: now)
            }
            if !spans.isEmpty {
                queue.enqueue(.telemetry, .traces, body: tracesBody(spans), now: now)
            }
        }
    }

    func pushLog(scope: String, record: JSON, kind: EnvelopeKind) {
        let json = record.serialized
        // An error goes to disk before capture returns, so killing the app in the next second cannot lose it.
        if kind == .errors {
            let body = logsBody([PendingLog(scope: scope, json: json)])
            let now = host.wallNow()
            queue.withLock { $0.enqueue(.errors, .logs, body: body, now: now) }
            pump()
            return
        }
        buffer(json) { $0.logs.append(PendingLog(scope: scope, json: json)) }
    }

    func pushSpan(_ span: JSON) {
        let json = span.serialized
        buffer(json) { $0.spans.append(json) }
    }

    private func buffer(_ json: String, append: (inout State) -> Void) {
        let full = state.withLock { state -> Bool in
            append(&state)
            state.bufferedBytes += json.utf8.count
            if state.logs.count + state.spans.count >= TransportTuning.batchRecords
                || state.bufferedBytes >= TransportTuning.batchBytes
            {
                defer { state.persistQueued = true }
                return !state.persistQueued
            }
            if state.batchTimer == nil {
                state.batchTimer = host.schedule(after: TransportTuning.batchDelayMilliseconds, on: work) { [self] in
                    persist()
                    pump()
                }
            }
            return false
        }
        if full {
            work.async { [self] in
                persist()
                pump()
            }
        }
    }

    // A pump that arrives while a drain is finishing would otherwise strand its envelope until the next trigger.
    private func pump(then done: (@Sendable () -> Void)? = nil) {
        enum Next { case finished, joined, start }
        let next = state.withLock { state -> Next in
            if state.stopped || state.retryTimer != nil {
                guard state.sending else { return .finished }
                if let done { state.drainWaiters.append(done) }
                return .joined
            }
            if let done { state.drainWaiters.append(done) }
            if state.sending {
                state.rerun = true
                return .joined
            }
            state.sending = true
            return .start
        }
        switch next {
        case .finished: done?()
        case .joined: break
        case .start: work.async { [self] in drainNext() }
        }
    }

    private func drainNext() {
        let stopped = state.withLock { $0.stopped }
        guard !stopped, let envelope = queue.withLock({ $0.oldest() }) else {
            finishDrain()
            return
        }
        let request = HTTPRequest(url: endpoint + envelope.meta.signal.path, headers: headers, body: envelope.body)
        host.send(request) { [self] result in
            work.async { [self] in handle(Outcome(result), for: envelope.meta.name) }
        }
    }

    private func handle(_ outcome: Outcome, for name: String) {
        let warnRejection = state.withLock { state -> Bool in
            guard outcome != .retry else {
                state.failures += 1
                let delay = backoffDelay(failures: state.failures, random: host.random())
                state.retryTimer = host.schedule(after: delay, on: work) { [self] in
                    self.state.withLock { $0.retryTimer = nil }
                    pump()
                }
                return false
            }
            state.failures = 0
            guard outcome == .rejected, !state.rejectionWarned else { return false }
            state.rejectionWarned = true
            return true
        }
        if outcome != .retry {
            queue.withLock { $0.remove(name) }
        }
        if warnRejection {
            warn("the ingest rejected a batch, so it was dropped; check the DSN")
        }
        if outcome == .retry {
            finishDrain()
        } else {
            drainNext()
        }
    }

    private func finishDrain() {
        let (waiters, rerun) = state.withLock { state in
            state.sending = false
            defer {
                state.drainWaiters = []
                state.rerun = false
            }
            return (state.drainWaiters, state.rerun)
        }
        for waiter in waiters { waiter() }
        if rerun { pump() }
    }

    func wake() {
        state.withLock { state in
            state.retryTimer?.cancel()
            state.retryTimer = nil
            state.failures = 0
        }
        pump()
    }

    func flush(_ done: @escaping @Sendable () -> Void) {
        persist()
        let sending = state.withLock { state -> Bool in
            state.retryTimer?.cancel()
            state.retryTimer = nil
            if state.sending {
                state.drainWaiters.append { [self] in pump(then: done) }
            }
            return state.sending
        }
        if !sending { pump(then: done) }
    }

    func stop() {
        persist()
        state.withLock { state in
            state.stopped = true
            state.retryTimer?.cancel()
            state.retryTimer = nil
        }
    }
}
