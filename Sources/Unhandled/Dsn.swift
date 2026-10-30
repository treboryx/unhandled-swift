import Foundation

struct Dsn: Sendable, Equatable {
    enum Mode: String, Sendable {
        case live, test
    }

    let apiKey: String
    let mode: Mode
    let endpoint: String
    let serviceId: String

    private static let pattern = try! NSRegularExpression(
        pattern: "^(https?)://([^/?#@:]+)@([^/?#@]+)/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$",
        options: [.caseInsensitive]
    )
    // `mk_` keys were issued before the product became Unhandled and still authenticate.
    private static let keyPattern = try! NSRegularExpression(pattern: "^(?:uh|mk)_(live|test)_[A-Za-z0-9_-]{16,56}$")
    private static let portSuffix = try! NSRegularExpression(pattern: ":([0-9]+)$")
    private static let defaultPorts = ["http": "80", "https": "443"]

    init?(_ input: String) {
        let whole = NSRange(input.startIndex..., in: input)
        guard let match = Dsn.pattern.firstMatch(in: input, range: whole),
              let user = Dsn.group(match, 2, in: input)?.removingPercentEncoding,
              let keyMatch = Dsn.keyPattern.firstMatch(in: user, range: NSRange(user.startIndex..., in: user)),
              let mode = Dsn.group(keyMatch, 1, in: user).flatMap(Mode.init(rawValue:)),
              let scheme = Dsn.group(match, 1, in: input)?.lowercased(),
              let host = Dsn.group(match, 3, in: input)?.lowercased(),
              let serviceId = Dsn.group(match, 4, in: input)?.lowercased()
        else { return nil }
        apiKey = user
        self.mode = mode
        endpoint = Dsn.origin(scheme: scheme, host: host)
        self.serviceId = serviceId
    }

    private static func origin(scheme: String, host: String) -> String {
        guard let port = portSuffix.firstMatch(in: host, range: NSRange(host.startIndex..., in: host)),
              let range = Range(port.range, in: host),
              let number = group(port, 1, in: host)
        else { return "\(scheme)://\(host)" }
        let name = host[..<range.lowerBound]
        return number == defaultPorts[scheme] ? "\(scheme)://\(name)" : "\(scheme)://\(name):\(number)"
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
        Range(match.range(at: index), in: text).map { String(text[$0]) }
    }
}
