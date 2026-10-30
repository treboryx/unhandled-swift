// Same construction as the React Native SDK, so ids built from one random source match byte for byte.
func randomHex(length: Int, random: () -> Double) -> String {
    var hex = ""
    while hex.count < length {
        let word = String(UInt32(min(random(), 0.999_999_999_9) * 4_294_967_296), radix: 16)
        hex += String(repeating: "0", count: 8 - word.count) + word
    }
    return String(hex.prefix(length))
}

func uuidv7(milliseconds: Int64, random: () -> Double) -> String {
    let fullTime = String(max(0, milliseconds), radix: 16)
    let padded = String(repeating: "0", count: max(0, 12 - fullTime.count)) + fullTime
    let time = Array(padded.suffix(12))
    let rest = Array(randomHex(length: 20, random: random))
    let variant = String((Int(String(rest[3]), radix: 16)! % 4) + 8, radix: 16)
    return String(time[0 ..< 8]) + "-" + String(time[8 ..< 12]) + "-7" + String(rest[0 ..< 3]) + "-" + variant
        + String(rest[4 ..< 7]) + "-" + String(rest[8 ..< 20])
}
