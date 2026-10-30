// FNV-1a over the UTF-8 bytes, then murmur3's finalizer, so every SDK lands a unit in the same bucket.
func hash32(_ text: String) -> UInt32 {
    var hash: UInt32 = 0x811C_9DC5
    for byte in text.utf8 {
        hash ^= UInt32(byte)
        hash = hash &* 0x0100_0193
    }
    hash ^= hash >> 16
    hash = hash &* 0x85EB_CA6B
    hash ^= hash >> 13
    hash = hash &* 0xC2B2_AE35
    hash ^= hash >> 16
    return hash
}

func experimentBucket(_ experiment: String, unitId: String) -> Double {
    Double(hash32("\(experiment):\(unitId)")) / 4_294_967_296
}

func assignVariant(_ experiment: String, unitId: String, variants: [Variant]) -> String {
    let total = variants.reduce(0) { $0 + $1.weight }
    let point = experimentBucket(experiment, unitId: unitId) * Double(total)
    var edge = 0
    for variant in variants {
        edge += variant.weight
        if point < Double(edge) {
            return variant.key
        }
    }
    return variants.last?.key ?? ""
}

func controlVariant(_ variants: [Variant]) -> String {
    variants.first?.key ?? ""
}
