import Foundation

enum Limits {
    static let nameBytes = 100
    static let propertyCount = 20
    static let propertyKeyBytes = 64
    static let stringValueBytes = 256
    static let userIdBytes = 256
    static let revenueIdBytes = 64
    static let productBytes = 128
    static let subscriptionIdBytes = 128
    static let maxAbsAmount: Int64 = 1_000_000_000_000
    static let minVariants = 2
    static let maxVariants = 5
    static let maxWeight = 100
}

enum PropertyRules {
    case event
    case profile
}

private let reservedNames: Set<String> = ["pageview", "revenue"]
private let reservedKeys: Set<String> = ["user_id", "userid", "email", "distinct_id", "anonymous_id", "session_id"]
private let reservedKeyPrefixes = ["user.", "trace.", "span.", "unhandled."]
private let reservedProfilePrefix = "unhandled."

private func hasControlCharacter(_ text: String) -> Bool {
    text.unicodeScalars.contains { $0.properties.generalCategory == .control }
}

private func fitsText(_ text: String, maxBytes: Int) -> Bool {
    text.utf8.count <= maxBytes && !hasControlCharacter(text)
}

private func isBlank(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

private func isReserved(_ key: String, rules: PropertyRules) -> Bool {
    let lowered = key.lowercased()
    switch rules {
    case .event:
        return reservedKeys.contains(lowered) || reservedKeyPrefixes.contains { lowered.hasPrefix($0) }
    case .profile:
        return lowered.hasPrefix(reservedProfilePrefix)
    }
}

private func isValidValue(_ value: AnalyticsValue, rules: PropertyRules) -> Bool {
    switch value {
    case let .string(text):
        text.utf8.count <= Limits.stringValueBytes && (rules == .event || !hasControlCharacter(text))
    case let .double(number):
        number.isFinite
    case .int, .bool:
        true
    }
}

func isValidProperties(_ properties: [String: AnalyticsValue], rules: PropertyRules) -> Bool {
    guard properties.count <= Limits.propertyCount else { return false }
    return properties.allSatisfy { key, value in
        !key.isEmpty
            && key.utf8.count <= Limits.propertyKeyBytes
            && !isReserved(key, rules: rules)
            && (rules == .event || !hasControlCharacter(key))
            && isValidValue(value, rules: rules)
    }
}

func isValidEventName(_ name: String) -> Bool {
    !name.isEmpty && name.utf8.count <= Limits.nameBytes && !reservedNames.contains(name)
}

func isValidUserId(_ userId: String) -> Bool {
    !isBlank(userId) && userId.utf8.count <= Limits.userIdBytes && !hasControlCharacter(userId)
}

struct ValidRevenue: Equatable {
    let amount: Int64
    let currency: String
    let product: String
    let subscription: Revenue.Subscription?
}

private let maxIntervalCount: [Revenue.Interval: Int] = [.day: 366, .week: 52, .month: 12, .year: 1]

private func isCurrency(_ text: String) -> Bool {
    text.unicodeScalars.count == 3
        && text.unicodeScalars.allSatisfy { $0.isASCII && $0.properties.isAlphabetic }
}

func validateRevenue(_ revenue: Revenue) -> ValidRevenue? {
    if let id = revenue.id, isBlank(id) || !fitsText(id, maxBytes: Limits.revenueIdBytes) {
        return nil
    }
    let product = revenue.product ?? ""
    guard revenue.amount.magnitude <= Limits.maxAbsAmount.magnitude,
          isCurrency(revenue.currency),
          fitsText(product, maxBytes: Limits.productBytes)
    else { return nil }
    if let subscription = revenue.subscription {
        guard !isBlank(subscription.id),
              fitsText(subscription.id, maxBytes: Limits.subscriptionIdBytes),
              let max = maxIntervalCount[subscription.interval],
              (1 ... max).contains(subscription.intervalCount)
        else { return nil }
    }
    return ValidRevenue(
        amount: revenue.amount,
        currency: revenue.currency.uppercased(),
        product: product,
        subscription: revenue.subscription
    )
}

func isExperimentKey(_ key: String) -> Bool {
    let bytes = Array(key.utf8)
    guard let first = bytes.first, bytes.count <= 64 else { return false }
    let isLowerOrDigit = { (byte: UInt8) in (0x61 ... 0x7A).contains(byte) || (0x30 ... 0x39).contains(byte) }
    return isLowerOrDigit(first) && bytes.dropFirst().allSatisfy { isLowerOrDigit($0) || $0 == 0x5F || $0 == 0x2D }
}

func validateVariants(_ variants: [Variant]) -> [Variant]? {
    guard (Limits.minVariants ... Limits.maxVariants).contains(variants.count) else { return nil }
    var seen = Set<String>()
    for variant in variants {
        guard isExperimentKey(variant.key),
              seen.insert(variant.key).inserted,
              (1 ... Limits.maxWeight).contains(variant.weight)
        else { return nil }
    }
    return variants
}
