import Foundation

struct NativeFrame: Sendable, Equatable {
    let function: String
    let image: String
    let inApp: Bool
    let instructionAddress: UInt64
    let imageAddress: UInt64?
    let imageUUID: String?

    var json: JSON {
        var members: [JSON.Member] = [
            .init("filename", .string(image)),
            .init("function", .string(function)),
            .init("lineno", .int(0)),
            .init("colno", .int(0)),
            .init("in_app", .bool(inApp)),
            .init("instruction_addr", .string(hex(instructionAddress))),
        ]
        if let imageAddress { members.append(.init("image_addr", .string(hex(imageAddress)))) }
        if let imageUUID { members.append(.init("image_uuid", .string(imageUUID))) }
        return .object(members)
    }
}

func hex(_ value: UInt64) -> String {
    let digits = String(value, radix: 16)
    return "0x" + String(repeating: "0", count: max(0, 16 - digits.count)) + digits
}

// The Apple crash report layout, which symbolication tools and readers already know.
func stacktraceText(_ frames: [NativeFrame]) -> String {
    frames.enumerated().map { index, frame in
        let number = String(index).padding(toLength: 4, withPad: " ", startingAt: 0)
        let image = frame.image.padding(toLength: max(frame.image.count, 32), withPad: " ", startingAt: 0)
        return "\(number)\(image) \(hex(frame.instructionAddress)) \(frame.function)"
    }.joined(separator: "\n")
}

enum Mechanism: String, Sendable {
    case manual
    case nsexception
    case signal
}

struct ExceptionNode {
    let type: String
    let message: String
    let frames: [NativeFrame]
    let children: [(source: String, node: () -> ExceptionNode?)]
    let identity: ObjectIdentifier?
}

struct ExceptionValue {
    let id: Int
    let parentId: Int?
    let source: String?
    let type: String
    let message: String
    let stacktrace: String
    let frames: [NativeFrame]
    let mechanism: Mechanism
    let handled: Bool
    let synthetic: Bool

    var json: JSON {
        let parent: JSON = parentId.map { .int(Int64($0)) } ?? .null
        let sourceValue: JSON = source.map { .string($0) } ?? .null
        return .object([
            .init("id", .int(Int64(id))),
            .init("parent_id", parent),
            .init("source", sourceValue),
            .init("type", .string(type)),
            .init("message", .string(message)),
            .init("stacktrace", .string(stacktrace)),
            .init("frames", .array(frames.map(\.json))),
            .init("mechanism", .object([
                .init("type", .string(mechanism.rawValue)),
                .init("handled", .bool(handled)),
                .init("synthetic", .bool(synthetic)),
                .init("exception_id", .int(Int64(id))),
                .init("parent_id", parent),
                .init("source", sourceValue),
                .init("is_exception_group", .bool(false)),
            ])),
        ])
    }
}

private enum ExceptionLimits {
    static let depth = 5
    static let values = 20
}

func flatten(_ root: ExceptionNode, mechanism: Mechanism, handled: Bool) -> [ExceptionValue] {
    var values: [ExceptionValue] = []
    var seen = Set<ObjectIdentifier>()
    func visit(_ node: ExceptionNode, parentId: Int?, source: String?, depth: Int) {
        guard values.count < ExceptionLimits.values, depth <= ExceptionLimits.depth else { return }
        if let identity = node.identity {
            guard seen.insert(identity).inserted else { return }
        }
        let id = values.count
        values.append(ExceptionValue(
            id: id,
            parentId: parentId,
            source: source,
            type: node.type,
            message: node.message,
            stacktrace: stacktraceText(node.frames),
            frames: node.frames,
            mechanism: mechanism,
            handled: handled,
            synthetic: false
        ))
        for child in node.children {
            if let next = child.node() {
                visit(next, parentId: id, source: child.source, depth: depth + 1)
            }
        }
    }
    visit(root, parentId: nil, source: nil, depth: 0)
    return values
}

func messageValues(_ message: String) -> [ExceptionValue] {
    [ExceptionValue(
        id: 0, parentId: nil, source: nil, type: "Message", message: message, stacktrace: "", frames: [],
        mechanism: .manual, handled: true, synthetic: true
    )]
}

// Private types reflect with a per-build address, which would split one error into a group per release.
private func typeName(_ type: Any.Type) -> String {
    String(reflecting: type).replacingOccurrences(
        of: #"\(unknown context at \$[0-9a-f]+\)\."#, with: "", options: .regularExpression
    )
}

private func isClassInstance(_ value: Any) -> Bool {
    type(of: value) is AnyClass
}

func errorNode(_ error: Error, frames: [NativeFrame]) -> ExceptionNode {
    let bridged = error as NSError
    let isNSError = Swift.type(of: error) is NSError.Type
    let type: String
    let message: String
    if let localized = error as? LocalizedError, let description = localized.errorDescription {
        type = isNSError ? "\(bridged.domain) (\(bridged.code))" : typeName(Swift.type(of: error))
        message = description
    } else if isNSError {
        type = "\(bridged.domain) (\(bridged.code))"
        message = bridged.localizedDescription
    } else {
        type = typeName(Swift.type(of: error))
        message = String(describing: error)
    }
    let underlying = bridged.userInfo[NSUnderlyingErrorKey] as? Error
    return ExceptionNode(
        type: type,
        message: message,
        frames: frames,
        children: underlying.map { cause in [("cause", { errorNode(cause, frames: []) })] } ?? [],
        identity: isClassInstance(error) ? ObjectIdentifier(error as AnyObject) : nil
    )
}

struct RecordContext {
    let occurrenceId: String
    let deviceTags: [(String, String)]
    let screen: String?
    let user: CaptureUser?
    let level: MessageLevel?
    let context: CaptureContext
}

private let maxExtraCharacters = 8192

func userAttributes(_ user: CaptureUser?) -> [(String, String)] {
    guard let user else { return [] }
    var attributes = [("user.id", user.id)]
    if let email = user.email, !email.isEmpty { attributes.append(("user.email", email)) }
    if let name = user.name, !name.isEmpty { attributes.append(("user.name", name)) }
    return attributes
}

func exceptionAttributes(_ values: [ExceptionValue], _ record: RecordContext) -> [(String, String)] {
    let root = values[0]
    let causes = values.dropFirst().filter { $0.source == "cause" }
    var attributes: [(String, String)] = [
        ("exception.type", root.type),
        ("exception.message", root.message),
        ("exception.stacktrace", ([root] + causes).map(\.stacktrace).joined(separator: "\n[cause]: ")),
        ("unhandled.exception.values", JSON.array(values.map(\.json)).serialized),
        ("unhandled.exception.values_version", "1"),
        ("unhandled.exception.frames", JSON.array(root.frames.map(\.json)).serialized),
    ]
    if !causes.isEmpty {
        let chain = causes.map { JSON.object([.init("type", .string($0.type)), .init("message", .string($0.message))]) }
        attributes.append(("unhandled.exception.cause_chain", JSON.array(chain).serialized))
    }
    attributes.append(("unhandled.log.source", "exception_reporter"))
    attributes.append(("unhandled.exception.occurrence_id", record.occurrenceId))
    if let level = record.level { attributes.append(("unhandled.message.level", level.rawValue)) }
    if let screen = record.screen { attributes.append(("app.screen.name", screen)) }
    var tags = record.deviceTags
    for (key, value) in record.context.tags.sorted(by: { $0.key < $1.key }) {
        if let position = tags.firstIndex(where: { $0.0 == key }) {
            tags[position].1 = value
        } else {
            tags.append((key, value))
        }
    }
    attributes += tags.map { ("unhandled.tag.\($0.0)", $0.1) }
    attributes += record.context.extra.sorted { $0.key < $1.key }.map { key, value in
        ("unhandled.extra.\(key)", String(value.description.prefix(maxExtraCharacters)))
    }
    return attributes + userAttributes(record.user)
}
