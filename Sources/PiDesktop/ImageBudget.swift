import Foundation

/// Aggregate ceiling for images admitted while projecting one conversation from its session file.
///
/// The budget is consulted with the *encoded* (base64) length so an oversized payload is
/// rejected before `Data(base64Encoded:)` ever materialises it, and both a count and a
/// total-byte limit apply across the whole conversation rather than per message.
struct ImageBudget {
    static let defaultCountLimit = 64
    static let defaultByteLimit = 64 * 1_024 * 1_024

    let countLimit: Int
    let byteLimit: Int
    private(set) var admittedCount = 0
    private(set) var admittedBytes = 0
    private(set) var omittedCount = 0

    init(countLimit: Int = ImageBudget.defaultCountLimit, byteLimit: Int = ImageBudget.defaultByteLimit) {
        self.countLimit = countLimit
        self.byteLimit = byteLimit
    }

    /// Decoded size of a base64 payload, ignoring padding subtleties (over-estimates by <=2 bytes).
    static func decodedByteEstimate(encodedLength: Int) -> Int { encodedLength / 4 * 3 }

    /// Returns true when an image of this encoded length may be decoded and retained.
    /// Rejections are counted so the caller can surface an explicit placeholder.
    mutating func admitEncoded(length: Int) -> Bool {
        let estimate = Self.decodedByteEstimate(encodedLength: length)
        guard length > 0,
              length <= PiTheme.imageByteLimit * 2,
              admittedCount < countLimit,
              admittedBytes + estimate <= byteLimit
        else {
            omittedCount += 1
            return false
        }
        admittedCount += 1
        admittedBytes += estimate
        return true
    }

    /// Called when a payload passed the pre-decode check but decoding produced a different
    /// (or invalid) size, keeping the running total honest.
    mutating func reconcile(estimatedFrom encodedLength: Int, actual: Int?) {
        let estimate = Self.decodedByteEstimate(encodedLength: encodedLength)
        guard let actual else {
            admittedCount = max(0, admittedCount - 1)
            admittedBytes = max(0, admittedBytes - estimate)
            omittedCount += 1
            return
        }
        admittedBytes = max(0, admittedBytes - estimate + actual)
    }

    static let omittedPlaceholder = "Image omitted: this conversation reached its image memory budget."
    static let invalidPlaceholder = "Image omitted because it was invalid or exceeded the import limit."
}
