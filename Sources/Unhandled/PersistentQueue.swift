import Foundation

enum EnvelopeKind: String, Sendable {
    case errors, telemetry
}

enum EnvelopeSignal: String, Sendable {
    case logs, traces

    var path: String { "/v1/\(rawValue)" }
}

struct EnvelopeMeta: Sendable, Equatable {
    let name: String
    let kind: EnvelopeKind
    let signal: EnvelopeSignal
    let bytes: Int

    // The name carries everything the index needs, so start-up lists the directory without reading a file.
    init?(name: String) {
        guard name.hasSuffix(".json") else { return nil }
        let parts = name.dropLast(5).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5,
              parts[0].count == 15, parts[0].allSatisfy(\.isASCIIDigit),
              parts[1].count == 6, parts[1].allSatisfy(\.isASCIIDigit),
              let kind = EnvelopeKind(rawValue: String(parts[2])),
              let signal = EnvelopeSignal(rawValue: String(parts[3])),
              !parts[4].isEmpty, parts[4].allSatisfy(\.isASCIIDigit),
              let bytes = Int(parts[4])
        else { return nil }
        self.name = name
        self.kind = kind
        self.signal = signal
        self.bytes = bytes
    }
}

struct Envelope: Sendable {
    let meta: EnvelopeMeta
    let body: String
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

private func padded(_ value: Int64, width: Int) -> String {
    let text = String(value)
    return String(repeating: "0", count: max(0, width - text.count)) + text
}

struct PersistentQueue {
    let directory: URL
    let limits: QueueLimits
    private(set) var index: [EnvelopeMeta]
    private(set) var dropped = 0
    private var sequence = 0

    init(directory: URL, limits: QueueLimits) {
        self.directory = directory
        self.limits = limits
        let files = FileManager.default
        try? files.createDirectory(at: directory, withIntermediateDirectories: true)
        var found: [EnvelopeMeta] = []
        for name in (try? files.contentsOfDirectory(atPath: directory.path)) ?? [] {
            var isDirectory: ObjCBool = false
            let path = directory.appendingPathComponent(name).path
            guard files.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            if let meta = EnvelopeMeta(name: name) {
                found.append(meta)
            } else {
                try? files.removeItem(atPath: path)
            }
        }
        index = found.sorted { $0.name < $1.name }
        enforce()
    }

    var totalBytes: Int { index.reduce(0) { $0 + $1.bytes } }

    private func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    private mutating func evict(at position: Int) {
        let meta = index.remove(at: position)
        try? FileManager.default.removeItem(at: url(meta.name))
        dropped += 1
    }

    // Errors outlive telemetry: a span storm while offline must not push out the crash that matters.
    private mutating func enforce() {
        while index.count > limits.maxEnvelopes || totalBytes > limits.maxBytes {
            evict(at: index.firstIndex { $0.kind == .telemetry } ?? 0)
        }
    }

    mutating func enqueue(_ kind: EnvelopeKind, _ signal: EnvelopeSignal, body: String, now: Double) {
        let data = Data(body.utf8)
        guard data.count <= limits.maxBytes else {
            dropped += 1
            return
        }
        sequence = (sequence + 1) % 1_000_000
        let name = "\(padded(Int64(now), width: 15))-\(padded(Int64(sequence), width: 6))-\(kind.rawValue)-"
            + "\(signal.rawValue)-\(data.count).json"
        do {
            try data.write(to: url(name), options: .atomic)
        } catch {
            dropped += 1
            return
        }
        index.append(EnvelopeMeta(name: name)!)
        enforce()
    }

    mutating func oldest() -> Envelope? {
        while let meta = index.first {
            if let data = try? Data(contentsOf: url(meta.name)), let body = String(data: data, encoding: .utf8) {
                return Envelope(meta: meta, body: body)
            }
            remove(meta.name)
        }
        return nil
    }

    mutating func remove(_ name: String) {
        index.removeAll { $0.name == name }
        try? FileManager.default.removeItem(at: url(name))
    }
}
