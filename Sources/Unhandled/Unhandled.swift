import Foundation

/// The Unhandled SDK. Call `Unhandled.start(_:)` once at launch, then use the returned client or `Unhandled.shared`.
public final class Unhandled: Sendable {
    public static let sdkName = SDK.name
    public static let sdkVersion = SDK.version

    private static let current = Locked<Unhandled?>(nil)
    private static let inactive = Unhandled(client: nil)

    private let client: Client?

    private init(client: Client?) {
        self.client = client
    }

    /// The started client, or an inactive one that sends nothing when `start` has not run.
    public static var shared: Unhandled {
        current.withLock { $0 } ?? inactive
    }

    public var isActive: Bool { client != nil }

    public var release: String? { client?.release }

    /// Starts the SDK. A second call returns the first client. An empty or invalid DSN returns an inactive client.
    @discardableResult
    public static func start(_ options: Options) -> Unhandled {
        start(options, host: SystemHost())
    }

    static func start(_ options: Options, host: any PlatformHost) -> Unhandled {
        current.withLock { current in
            if let current {
                warn("start() ran again; keeping the first client")
                return current
            }
            guard options.enabled, !options.dsn.isEmpty else { return inactive }
            guard let dsn = Dsn(options.dsn) else {
                warn("the dsn is not a valid DSN, so nothing is sent")
                return inactive
            }
            let started = Unhandled(client: Client(options: options, dsn: dsn, host: host))
            current = started
            return started
        }
    }

    public func captureError(_ error: Error, context: CaptureContext = CaptureContext()) {
        client?.captureError(error, context: context)
    }

    #if canImport(ObjectiveC)
    public func captureException(_ exception: NSException, context: CaptureContext = CaptureContext()) {
        client?.captureException(
            type: exception.name.rawValue,
            message: exception.reason ?? "",
            frames: liveFrames(exception.callStackReturnAddresses.map(\.uint64Value)),
            object: exception,
            context: context
        )
    }
    #endif

    public func captureMessage(_ message: String, level: MessageLevel = .info, context: CaptureContext = CaptureContext()) {
        client?.captureMessage(message, level: level, context: context)
    }

    /// The user attached to errors. `identify` sets it too.
    public func setUser(_ user: CaptureUser?) {
        client?.setUser(user)
    }

    /// Names the signed-in user for analytics and errors. Until then analytics are anonymous.
    public func identify(_ userId: String, properties: [String: AnalyticsValue] = [:]) {
        client?.identify(userId, properties: properties)
    }

    /// Updates the identified user's profile; does nothing before `identify`.
    public func setUserProperties(_ properties: [String: AnalyticsValue]) {
        client?.setUserProperties(properties)
    }

    /// Forgets the identified user, for example on sign-out.
    public func reset() {
        client?.reset()
    }

    public func track(_ name: String, properties: [String: AnalyticsValue] = [:]) {
        client?.track(name, properties: properties)
    }

    public func trackRevenue(_ revenue: Revenue) {
        client?.trackRevenue(revenue)
    }

    /// The identified user's variant, the same on every call and in every SDK, recorded as an exposure once per run.
    /// Before `identify` it returns the first variant and records nothing.
    public func getVariant(_ experiment: String, variants: [Variant]) -> String {
        client?.variant(experiment, variants: variants) ?? (variants.first?.key ?? "")
    }

    /// Records that the identified user saw a variant you assigned yourself; does nothing before `identify`.
    public func trackExposure(_ experiment: String, variant: String) {
        client?.trackExposure(experiment, variant: variant)
    }

    /// Sets the current screen. A change emits a screen span; the first screen also ends the cold start span.
    public func trackScreen(_ name: String) {
        client?.trackScreen(name)
    }

    /// Ends the cold start span at the next frame, for apps that do not call `trackScreen`.
    public func appReady() {
        client?.appReady()
    }

    /// Writes buffered telemetry to disk and sends the queue; returns once it is empty or a send failed.
    public func flush() async {
        await client?.flush()
    }

    /// Removes the crash handlers, flushes, and stops the client. A later `start` creates a new one.
    public func shutdown() async {
        guard let client else { return }
        await client.shutdown()
        Unhandled.current.withLock { current in
            if current === self { current = nil }
        }
    }
}
