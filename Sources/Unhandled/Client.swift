import Foundation

enum SDK {
    static let name = "@unhandled/swift"
    static let version = "0.1.0"
    static let analyticsScope = "unhandled.analytics"
}

private struct WeakObject {
    weak var object: AnyObject?
}

private func clampRate(_ rate: Double) -> Double {
    rate.isFinite ? min(1, max(0, rate)) : 1
}

final class Client: Sendable {
    private struct State {
        var user: CaptureUser?
        var identifiedId: String?
        // One exposure per unit and variant per run is enough; the results count each unit once anyway.
        var exposed = Set<String>()
        var screen: String?
        var stopped = false
        var shuttingDown = false
        var reported: [WeakObject] = []
        var coldStartPending: Bool
        var backgrounded = false
        var cleanups: [@Sendable () -> Void] = []
    }

    let release: String?
    private let host: any PlatformHost
    private let transport: Transport
    private let deviceTags: [(String, String)]
    private let errorRate: Double
    private let traceRate: Double
    private let ignoreRules: [IgnoreRule]
    private let startedAt: Double?
    private let state: Locked<State>

    init(options: Options, dsn: Dsn, host: any PlatformHost) {
        self.host = host
        let device = host.device()
        release = options.release ?? host.identity()?.release
        deviceTags = [("os.name", device.osName), ("device.class", device.deviceClass.rawValue)]
        errorRate = clampRate(options.sampleRate)
        traceRate = clampRate(options.tracesSampleRate)
        ignoreRules = options.ignoreErrors
        startedAt = host.startupTime()
        state = Locked(State(coldStartPending: startedAt != nil))

        var resource: [(String, String)] = release.map { [("service.version", $0)] } ?? []
        resource += [
            ("telemetry.sdk.language", "swift"),
            ("telemetry.sdk.name", SDK.name),
            ("telemetry.sdk.version", SDK.version),
            ("unhandled.sdk.name", SDK.name),
            ("unhandled.sdk.version", SDK.version),
            ("os.name", device.osName),
            ("os.version", device.osVersion),
            ("device.class", device.deviceClass.rawValue),
        ]
        let directory = options.storageDirectory ?? host.storageDirectory(serviceId: dsn.serviceId)
        transport = Transport(
            endpoint: dsn.endpoint,
            headers: [
                ("x-api-key", dsn.apiKey),
                ("x-unhandled-service-id", dsn.serviceId),
                ("x-unhandled-env", options.environment.rawValue),
            ],
            resource: stringAttributes(resource),
            queue: PersistentQueue(directory: directory, limits: options.queueLimits),
            host: host
        )

        let stopLifecycle = host.onAppState { [weak self] state in self?.appStateChanged(state) }
        state.withLock { $0.cleanups.append(stopLifecycle) }
        if options.captureCrashes {
            let crashDirectory = directory.appendingPathComponent(CrashFiles.directoryName)
            if let crash = takePendingCrash(in: crashDirectory) {
                report(
                    ExceptionNode(type: crash.type, message: crash.message, frames: crash.frames, children: [], identity: nil),
                    object: nil, mechanism: .signal, handled: false, context: CaptureContext(), at: crash.timeMilliseconds
                )
            }
            let handlers = host.installCrashHandlers(directory: crashDirectory) { [weak self] exception in
                self?.reportUncaught(exception)
            }
            if let handlers {
                state.withLock { $0.cleanups.append(handlers.uninstall) }
            }
        }
        transport.wake()
    }

    private func pushRecord(
        level: MessageLevel,
        body: BodyValue,
        attributes: [(String, BodyValue)],
        kind: EnvelopeKind,
        scope: String = SDK.name,
        at time: Double? = nil
    ) {
        let timestamp = unixNano(milliseconds: time ?? host.wallNow())
        let severity = Severity.of(level)
        let record = JSON.object([
            .init("timeUnixNano", .string(timestamp)),
            .init("observedTimeUnixNano", .string(timestamp)),
            .init("severityNumber", .int(severity.number)),
            .init("severityText", .string(severity.text)),
            .init("body", body.anyValue),
            .init("attributes", keyValues(attributes)),
        ])
        transport.pushLog(scope: scope, record: record, kind: kind)
    }

    private func report(
        _ node: ExceptionNode,
        object: AnyObject?,
        mechanism: Mechanism,
        handled: Bool,
        context: CaptureContext,
        at time: Double? = nil
    ) {
        let snapshot = state.withLock { state -> (CaptureUser?, String?)? in
            let seen = object.map { object in state.reported.contains { $0.object === object } } ?? false
            guard !state.stopped, !seen else { return nil }
            return (state.user, state.screen)
        }
        guard let (user, screen) = snapshot, host.random() < errorRate else { return }
        let values = flatten(node, mechanism: mechanism, handled: handled)
        let event = ErrorEvent(type: values[0].type, message: values[0].message, mechanism: mechanism.rawValue)
        guard !ignoreRules.contains(where: { $0.matches(event) }) else { return }
        if let object {
            state.withLock { state in
                state.reported.removeAll { $0.object == nil }
                state.reported.append(WeakObject(object: object))
            }
        }
        let occurredAt = time ?? host.wallNow()
        let attributes = exceptionAttributes(values, RecordContext(
            occurrenceId: uuidv7(milliseconds: Int64(occurredAt), random: host.random),
            deviceTags: deviceTags,
            screen: screen,
            user: context.user ?? user,
            level: nil,
            context: context
        ))
        pushRecord(
            level: handled ? .error : .fatal,
            body: .string(event.message),
            attributes: attributes.map { ($0.0, .string($0.1)) },
            kind: .errors,
            at: time
        )
    }

    private func reportUncaught(_ exception: UncaughtException) {
        report(
            ExceptionNode(type: exception.type, message: exception.message, frames: exception.frames, children: [], identity: nil),
            object: exception.object, mechanism: .nsexception, handled: false, context: CaptureContext()
        )
        transport.persist()
    }

    func captureError(_ error: Error, context: CaptureContext) {
        let object: AnyObject? = type(of: error as Any) is AnyClass ? error as AnyObject : nil
        report(errorNode(error, frames: currentStack()), object: object, mechanism: .manual, handled: true, context: context)
    }

    func captureException(type: String, message: String, frames: [NativeFrame], object: AnyObject, context: CaptureContext) {
        report(
            ExceptionNode(type: type, message: message, frames: frames.isEmpty ? currentStack() : frames, children: [], identity: nil),
            object: object, mechanism: .manual, handled: true, context: context
        )
    }

    func captureMessage(_ message: String, level: MessageLevel, context: CaptureContext) {
        guard let (user, screen) = state.withLock({ $0.stopped ? nil : ($0.user, $0.screen) }) else { return }
        let attributes = exceptionAttributes(messageValues(message), RecordContext(
            occurrenceId: uuidv7(milliseconds: Int64(host.wallNow()), random: host.random),
            deviceTags: deviceTags,
            screen: screen,
            user: context.user ?? user,
            level: level,
            context: context
        ))
        pushRecord(level: level, body: .string(message), attributes: attributes.map { ($0.0, .string($0.1)) }, kind: .errors)
    }

    private func sendAnalytics(
        kind: String,
        name: String?,
        properties: [String: AnalyticsValue],
        revenue: ValidRevenue? = nil,
        eventId: String? = nil,
        userId: String?
    ) {
        let now = host.wallNow()
        var body: [(String, BodyValue)] = [
            ("event_id", .string(eventId ?? uuidv7(milliseconds: Int64(now), random: host.random))),
            ("occurred_at_ms", .int(Int64(now))),
            ("kind", .string(kind)),
        ]
        if let name { body.append(("name", .string(name))) }
        body += [("site", .string("")), ("path", .string("")), ("referrer", .string("")), ("properties", .properties(properties))]
        if let revenue {
            body.append(("revenue", .map([
                ("amount", .int(revenue.amount)),
                ("currency", .string(revenue.currency)),
                ("product", .string(revenue.product)),
                ("subscription_id", .string(revenue.subscription?.id ?? "")),
                ("subscription_interval", .string(revenue.subscription?.interval.rawValue ?? "")),
                ("subscription_interval_count", .int(Int64(revenue.subscription?.intervalCount ?? 0))),
            ])))
        }
        var attributes: [(String, BodyValue)] = [("unhandled.analytics.version", .string("1"))]
        if let userId { attributes.append(("user.id", .string(userId))) }
        pushRecord(level: .info, body: .map(body), attributes: attributes, kind: .telemetry, scope: SDK.analyticsScope)
    }

    private var activeIdentity: (stopped: Bool, userId: String?) {
        state.withLock { ($0.stopped, $0.identifiedId) }
    }

    private func sendProfile(_ userId: String, properties: [String: AnalyticsValue]) -> Bool {
        guard !activeIdentity.stopped, isValidUserId(userId), isValidProperties(properties, rules: .profile) else {
            return false
        }
        sendAnalytics(kind: "identify", name: nil, properties: properties, userId: userId)
        return true
    }

    func setUser(_ user: CaptureUser?) {
        state.withLock { $0.user = user }
    }

    func identify(_ userId: String, properties: [String: AnalyticsValue]) {
        guard sendProfile(userId, properties: properties) else { return }
        state.withLock { state in
            state.identifiedId = userId
            if state.user?.id != userId {
                state.user = CaptureUser(id: userId)
            }
        }
    }

    func setUserProperties(_ properties: [String: AnalyticsValue]) {
        if let userId = activeIdentity.userId {
            _ = sendProfile(userId, properties: properties)
        }
    }

    func reset() {
        state.withLock { state in
            state.identifiedId = nil
            state.user = nil
        }
    }

    func track(_ name: String, properties: [String: AnalyticsValue]) {
        let (stopped, userId) = activeIdentity
        guard !stopped, isValidEventName(name), isValidProperties(properties, rules: .event) else { return }
        sendAnalytics(kind: "event", name: name, properties: properties, userId: userId)
    }

    func trackRevenue(_ revenue: Revenue) {
        let (stopped, userId) = activeIdentity
        guard !stopped, let valid = validateRevenue(revenue), isValidProperties(revenue.properties, rules: .event) else {
            return
        }
        sendAnalytics(
            kind: "revenue", name: "revenue", properties: revenue.properties, revenue: valid, eventId: revenue.id,
            userId: userId
        )
    }

    private func sendExposure(_ experiment: String, variant: String, userId: String) {
        guard !activeIdentity.stopped, isExperimentKey(experiment), isExperimentKey(variant) else { return }
        sendAnalytics(
            kind: "event", name: "experiment_exposure",
            properties: ["experiment": .string(experiment), "variant": .string(variant)], userId: userId
        )
    }

    // Exposures are counted per identified user; an app has no visitor id, so without one an exposure counts nowhere.
    func variant(_ experiment: String, variants: [Variant]) -> String {
        guard let parsed = validateVariants(variants), isExperimentKey(experiment),
              let unitId = activeIdentity.userId
        else { return controlVariant(variants) }
        let variant = assignVariant(experiment, unitId: unitId, variants: parsed)
        let first = state.withLock { $0.exposed.insert("\(experiment)\n\(unitId)\n\(variant)").inserted }
        if first {
            sendExposure(experiment, variant: variant, userId: unitId)
        }
        return variant
    }

    func trackExposure(_ experiment: String, variant: String) {
        if let userId = activeIdentity.userId {
            sendExposure(experiment, variant: variant, userId: userId)
        }
    }

    private func emitSpan(name: String, start: Double, end: Double, attributes: [(String, String)]) {
        guard let screen = state.withLock({ $0.stopped ? nil : .some($0.screen) }), host.random() < traceRate else {
            return
        }
        var spanAttributes = attributes
        if let screen, !attributes.contains(where: { $0.0 == "app.screen.name" }) {
            spanAttributes.append(("app.screen.name", screen))
        }
        transport.pushSpan(.object([
            .init("traceId", .string(randomHex(length: 32, random: host.random))),
            .init("spanId", .string(randomHex(length: 16, random: host.random))),
            .init("name", .string(name)),
            .init("kind", .int(SpanConstants.kindInternal)),
            .init("flags", .int(SpanConstants.rootFlags)),
            .init("startTimeUnixNano", .string(unixNano(milliseconds: start))),
            .init("endTimeUnixNano", .string(unixNano(milliseconds: max(start, end)))),
            .init("attributes", stringAttributes(spanAttributes)),
            .init("status", .object([.init("code", .int(0))])),
        ]))
    }

    func appReady() {
        guard let startedAt, state.withLock({ state in
            defer { state.coldStartPending = false }
            return state.coldStartPending
        }) else { return }
        host.nextFrame { [self] in
            let end = host.wallNow()
            let elapsed = host.monotonicNow() - startedAt
            guard elapsed > 0, elapsed <= 60000 else { return }
            emitSpan(name: "app start", start: end - elapsed, end: end, attributes: [("app.start.type", "cold")])
        }
    }

    func trackScreen(_ name: String) {
        guard !name.isEmpty else { return }
        let previous = state.withLock { state -> String?? in
            guard !state.stopped, state.screen != name else { return nil }
            defer { state.screen = name }
            return .some(state.screen)
        }
        guard let previous else { return }
        let start = host.wallNow()
        host.nextFrame { [self] in
            var attributes = [("app.screen.name", name)]
            if let previous { attributes.append(("app.screen.previous", previous)) }
            emitSpan(name: name, start: start, end: host.wallNow(), attributes: attributes)
            if previous == nil { appReady() }
        }
    }

    private func appStateChanged(_ appState: AppState) {
        switch appState {
        case .background:
            state.withLock { $0.backgrounded = true }
            transport.persist()
        case .active:
            transport.wake()
            let resumed = state.withLock { state in
                defer { state.backgrounded = false }
                return state.backgrounded
            }
            guard resumed else { return }
            let start = host.wallNow()
            host.nextFrame { [self] in
                emitSpan(name: "app resume", start: start, end: host.wallNow(), attributes: [("app.start.type", "resume")])
            }
        }
    }

    func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            transport.flush { continuation.resume() }
        }
    }

    func shutdown() async {
        let cleanups = state.withLock { state -> [@Sendable () -> Void]? in
            guard !state.stopped, !state.shuttingDown else { return nil }
            state.shuttingDown = true
            defer { state.cleanups = [] }
            return state.cleanups
        }
        guard let cleanups else { return }
        cleanups.reversed().forEach { $0() }
        await flush()
        state.withLock { $0.stopped = true }
        transport.stop()
    }
}
