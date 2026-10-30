import Foundation

public enum Environment: String, Sendable, CaseIterable {
    case production
    case staging
    case development
}

public struct QueueLimits: Sendable, Equatable {
    public var maxBytes: Int
    public var maxEnvelopes: Int

    public init(maxBytes: Int = 4_000_000, maxEnvelopes: Int = 200) {
        self.maxBytes = maxBytes
        self.maxEnvelopes = maxEnvelopes
    }
}

public struct ErrorEvent: Sendable, Equatable {
    public let type: String
    public let message: String
    public let mechanism: String
}

public enum IgnoreRule: Sendable, ExpressibleByStringLiteral {
    case messageContains(String)
    case matching(@Sendable (ErrorEvent) -> Bool)

    public init(stringLiteral value: String) {
        self = .messageContains(value)
    }

    func matches(_ event: ErrorEvent) -> Bool {
        switch self {
        case let .messageContains(text): event.message.contains(text)
        case let .matching(predicate): predicate(event)
        }
    }
}

public struct Options: Sendable {
    public var dsn: String
    public var environment: Environment
    /// Defaults to `bundleId@version+build` on Apple platforms.
    public var release: String?
    public var sampleRate: Double
    public var tracesSampleRate: Double
    public var ignoreErrors: [IgnoreRule]
    public var queueLimits: QueueLimits
    public var enabled: Bool
    public var storageDirectory: URL?
    public var captureCrashes: Bool

    public init(
        dsn: String,
        environment: Environment,
        release: String? = nil,
        sampleRate: Double = 1,
        tracesSampleRate: Double = 1,
        ignoreErrors: [IgnoreRule] = [],
        queueLimits: QueueLimits = QueueLimits(),
        enabled: Bool = true,
        storageDirectory: URL? = nil,
        captureCrashes: Bool = true
    ) {
        self.dsn = dsn
        self.environment = environment
        self.release = release
        self.sampleRate = sampleRate
        self.tracesSampleRate = tracesSampleRate
        self.ignoreErrors = ignoreErrors
        self.queueLimits = queueLimits
        self.enabled = enabled
        self.storageDirectory = storageDirectory
        self.captureCrashes = captureCrashes
    }
}

public enum AnalyticsValue: Sendable, Equatable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral
{
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

public struct Variant: Sendable, Equatable, ExpressibleByStringLiteral {
    public var key: String
    public var weight: Int

    public init(_ key: String, weight: Int = 1) {
        self.key = key
        self.weight = weight
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }
}

public struct Revenue: Sendable, Equatable {
    public enum Interval: String, Sendable, CaseIterable {
        case day, week, month, year
    }

    public struct Subscription: Sendable, Equatable {
        public var id: String
        public var interval: Interval
        public var intervalCount: Int

        public init(id: String, interval: Interval, intervalCount: Int = 1) {
            self.id = id
            self.interval = interval
            self.intervalCount = intervalCount
        }
    }

    /// Minor units of the currency: 1999 is $19.99. Negative is a refund.
    public var amount: Int64
    public var currency: String
    /// The payment provider's charge id; resending the same id counts the charge once.
    public var id: String?
    public var product: String?
    public var subscription: Subscription?
    public var properties: [String: AnalyticsValue]

    public init(
        amount: Int64,
        currency: String,
        id: String? = nil,
        product: String? = nil,
        subscription: Subscription? = nil,
        properties: [String: AnalyticsValue] = [:]
    ) {
        self.amount = amount
        self.currency = currency
        self.id = id
        self.product = product
        self.subscription = subscription
        self.properties = properties
    }
}

public struct CaptureUser: Sendable, Equatable {
    public var id: String
    public var email: String?
    public var name: String?

    public init(id: String, email: String? = nil, name: String? = nil) {
        self.id = id
        self.email = email
        self.name = name
    }
}

public struct CaptureContext: Sendable {
    public var tags: [String: String]
    public var extra: [String: any CustomStringConvertible & Sendable]
    public var user: CaptureUser?

    public init(
        tags: [String: String] = [:],
        extra: [String: any CustomStringConvertible & Sendable] = [:],
        user: CaptureUser? = nil
    ) {
        self.tags = tags
        self.extra = extra
        self.user = user
    }
}

public enum MessageLevel: String, Sendable, CaseIterable {
    case debug, info, log, warning, error, fatal
}
