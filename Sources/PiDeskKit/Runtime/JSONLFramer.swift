import Foundation

/// Pi RPC uses strict LF-delimited JSONL. This intentionally does not treat CR,
/// U+2028, or U+2029 as record delimiters.
public struct JSONLFramer: Sendable {
    public init() {}

    private(set) var buffer = Data()

    public mutating func append(_ chunk: Data) -> [Data] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(chunk)

        var records: [Data] = []
        var recordStart = buffer.startIndex
        var cursor = recordStart

        while cursor < buffer.endIndex {
            if buffer[cursor] == 0x0A {
                var record = buffer[recordStart..<cursor]
                if record.last == 0x0D {
                    record = record.dropLast()
                }
                if !record.isEmpty {
                    records.append(Data(record))
                }
                recordStart = buffer.index(after: cursor)
            }
            cursor = buffer.index(after: cursor)
        }

        if recordStart > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<recordStart)
        }
        return records
    }

    public mutating func finish() -> Data? {
        guard !buffer.isEmpty else { return nil }
        var record = buffer
        buffer.removeAll(keepingCapacity: false)
        if record.last == 0x0D {
            record.removeLast()
        }
        return record.isEmpty ? nil : record
    }
}

public enum JSONLFileReader {
    public static func read(url: URL, onRecord: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var framer = JSONLFramer()
        var capturedError: Error?
        var reachedEnd = false

        while !reachedEnd, capturedError == nil {
            if Task.isCancelled { throw CancellationError() }
            autoreleasepool {
                do {
                    guard let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty else {
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
        // A session writer may be between writes. JSONL records are visible only after their LF,
        // so a torn final object is ignored now and parsed on the next retry once completed.
    }
}
