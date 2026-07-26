import Foundation

/// Splits a byte stream into LF-delimited JSON records. Shared by session-file scanning and the
/// runner's `pi --mode rpc` stdout, which both speak strict LF-delimited JSONL. Ported from the
/// app's `JSONLFramer` (`Sources/PiDesktop/JSONLFramer.swift`, not importable from here).
/// Deliberately does not treat CR, U+2028, or U+2029 as record delimiters.
public struct JSONLFramer: Sendable {
    private(set) var buffer = Data()

    public init() {}

    public mutating func append(_ chunk: Data) -> [Data] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(chunk)

        var records: [Data] = []
        var recordStart = buffer.startIndex
        var cursor = recordStart

        while cursor < buffer.endIndex {
            if buffer[cursor] == 0x0A {
                var record = buffer[recordStart..<cursor]
                if record.last == 0x0D { record = record.dropLast() }
                if !record.isEmpty { records.append(Data(record)) }
                recordStart = buffer.index(after: cursor)
            }
            cursor = buffer.index(after: cursor)
        }

        if recordStart > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<recordStart)
        }
        return records
    }

    /// Flushes a trailing partial record with no terminating LF (end of stream/file).
    public mutating func finish() -> Data? {
        guard !buffer.isEmpty else { return nil }
        var record = buffer
        buffer.removeAll(keepingCapacity: false)
        if record.last == 0x0D { record.removeLast() }
        return record.isEmpty ? nil : record
    }
}

/// Streams a JSONL file in bounded chunks so a summary scan never holds the whole file in
/// memory, regardless of session size.
public enum JSONLFileReader {
    public static func read(url: URL, chunkSize: Int = 256 * 1_024, onRecord: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var framer = JSONLFramer()
        var capturedError: Error?
        var reachedEnd = false

        while !reachedEnd, capturedError == nil {
            if Task.isCancelled { throw CancellationError() }
            autoreleasepool {
                do {
                    guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                        reachedEnd = true
                        return
                    }
                    for record in framer.append(chunk) {
                        try Task.checkCancellation()
                        try onRecord(record)
                    }
                } catch {
                    capturedError = error
                }
            }
        }

        if let capturedError { throw capturedError }
        if let trailing = framer.finish() { try onRecord(trailing) }
    }
}
