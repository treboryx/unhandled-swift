import Foundation

// Object keys keep insertion order so the wire bytes match the React Native SDK's JSON.stringify output.
indirect enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([Member])

    struct Member: Sendable, Equatable {
        let key: String
        let value: JSON

        init(_ key: String, _ value: JSON) {
            self.key = key
            self.value = value
        }
    }

    var serialized: String {
        var output = ""
        write(to: &output)
        return output
    }

    private func write(to output: inout String) {
        switch self {
        case .null:
            output += "null"
        case let .bool(value):
            output += value ? "true" : "false"
        case let .int(value):
            output += String(value)
        case let .double(value):
            output += value.isFinite ? "\(value)" : "null"
        case let .string(value):
            JSON.writeString(value, to: &output)
        case let .array(items):
            output += "["
            for (index, item) in items.enumerated() {
                if index > 0 { output += "," }
                item.write(to: &output)
            }
            output += "]"
        case let .object(members):
            output += "{"
            for (index, member) in members.enumerated() {
                if index > 0 { output += "," }
                JSON.writeString(member.key, to: &output)
                output += ":"
                member.value.write(to: &output)
            }
            output += "}"
        }
    }

    private static func writeString(_ value: String, to output: inout String) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case _ where scalar.value < 0x20:
                let hex = String(scalar.value, radix: 16)
                output += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }
}

indirect enum BodyValue: Sendable, Equatable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case map([(String, BodyValue)])

    static func == (left: BodyValue, right: BodyValue) -> Bool {
        left.anyValue == right.anyValue
    }

    init(_ value: AnalyticsValue) {
        switch value {
        case let .string(text): self = .string(text)
        case let .int(number): self = .int(Int64(number))
        case let .double(number): self = .double(number)
        case let .bool(flag): self = .bool(flag)
        }
    }

    static func properties(_ properties: [String: AnalyticsValue]) -> BodyValue {
        .map(properties.sorted { $0.key < $1.key }.map { ($0.key, BodyValue($0.value)) })
    }

    var anyValue: JSON {
        switch self {
        case let .string(text):
            return .object([.init("stringValue", .string(text))])
        case let .bool(flag):
            return .object([.init("boolValue", .bool(flag))])
        case let .int(number):
            return .object([.init("intValue", .string(String(number)))])
        case let .double(number):
            if number.rounded() == number, let integer = Int64(exactly: number) {
                return .object([.init("intValue", .string(String(integer)))])
            }
            return .object([.init("doubleValue", .double(number))])
        case let .map(entries):
            return .object([.init("kvlistValue", .object([.init("values", keyValues(entries))]))])
        }
    }
}

func keyValues(_ entries: [(String, BodyValue)]) -> JSON {
    .array(entries.map { .object([.init("key", .string($0.0)), .init("value", $0.1.anyValue)]) })
}

func stringAttributes(_ entries: [(String, String)]) -> JSON {
    keyValues(entries.map { ($0.0, .string($0.1)) })
}

func unixNano(milliseconds: Double) -> String {
    String(Int64((milliseconds * 1000).rounded()) * 1000)
}

enum Severity {
    static func of(_ level: MessageLevel) -> (number: Int64, text: String) {
        switch level {
        case .debug: (5, "DEBUG")
        case .info, .log: (9, "INFO")
        case .warning: (13, "WARN")
        case .error: (17, "ERROR")
        case .fatal: (21, "FATAL")
        }
    }
}

enum SpanConstants {
    static let kindInternal: Int64 = 1
    // HAS_IS_REMOTE set, IS_REMOTE clear: the backend reads this as a local root, not a lost parent.
    static let rootFlags: Int64 = 0x100
}
