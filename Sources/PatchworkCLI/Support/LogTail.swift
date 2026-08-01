import Foundation

/// Bounded reads of the daemon log file: `lastLines` never loads more than `maxBytes` from the
/// tail regardless of how large the log has grown, and `--follow` reads in small chunks rather
/// than the whole remainder at once.
enum LogTail {
    static func lastLines(of url: URL, count: Int, maxBytes: Int = 2_000_000) throws -> [String] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let readSize = min(Int(size), maxBytes)
        try handle.seek(toOffset: size - UInt64(readSize))
        let data = handle.readData(ofLength: readSize)
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return Array(lines.suffix(count))
    }

    /// Reads whatever is available past the handle's current offset, one bounded chunk at a time.
    static func readAppended(_ handle: FileHandle, maxChunk: Int = 65_536) -> String {
        var text = ""
        while let chunk = try? handle.read(upToCount: maxChunk), !chunk.isEmpty {
            text += String(decoding: chunk, as: UTF8.self)
            if chunk.count < maxChunk { break }
        }
        return text
    }
}
