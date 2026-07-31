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
    /// Reads every record in the file.
    public static func read(url: URL, onRecord: (Data) throws -> Void) throws {
        try read(url: url, window: nil, onRecord: onRecord)
    }

    /// How a very large session file is sampled when a full pass is not affordable. The head
    /// carries a conversation's identity (its session record, its first user turn) and the tail
    /// carries its current state, so reading both ends answers everything a sidebar row needs
    /// while skipping a middle that can run to hundreds of megabytes.
    public struct ReadWindow: Sendable {
        public let headBytes: Int
        public let tailBytes: Int
        /// Files at or below this size are read whole; the window only applies above it.
        public let fullReadLimit: Int

        public init(headBytes: Int, tailBytes: Int, fullReadLimit: Int) {
            self.headBytes = headBytes
            self.tailBytes = tailBytes
            self.fullReadLimit = fullReadLimit
        }

        /// Sized so an ordinary Pi or Claude session is always read whole, and only genuinely
        /// oversized transcripts (Codex rollouts reach hundreds of megabytes) are sampled.
        public static let `default` = ReadWindow(
            headBytes: 4 * 1_024 * 1_024, tailBytes: 8 * 1_024 * 1_024, fullReadLimit: 24 * 1_024 * 1_024
        )
    }

    /// True when this file would be sampled rather than read whole, so a caller can report that
    /// its derived numbers are partial instead of quietly presenting them as exact.
    public static func isWindowed(url: URL, window: ReadWindow = .default) -> Bool {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size > window.fullReadLimit
    }

    public static func read(url: URL, window: ReadWindow?, onRecord: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        if let window {
            let size = Int((try? handle.seekToEnd()) ?? 0)
            try handle.seek(toOffset: 0)
            if size > window.fullReadLimit {
                try readWindowed(handle: handle, size: size, window: window, onRecord: onRecord)
                return
            }
        }

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

    /// Head then tail, each aligned to record boundaries. The first partial record of the tail
    /// is discarded rather than guessed at, so a caller never sees a half record.
    private static func readWindowed(
        handle: FileHandle, size: Int, window: ReadWindow, onRecord: (Data) throws -> Void
    ) throws {
        try handle.seek(toOffset: 0)
        let head = (try handle.read(upToCount: window.headBytes)) ?? Data()
        var framer = JSONLFramer()
        for record in framer.append(head) {
            try Task.checkCancellation()
            try onRecord(record)
        }

        let tailStart = max(window.headBytes, size - window.tailBytes)
        guard tailStart < size else { return }
        try handle.seek(toOffset: UInt64(tailStart))
        var tail = (try handle.readToEnd()) ?? Data()
        // Drop whatever precedes the first newline: it is the tail end of a record whose start
        // was skipped.
        if let firstNewline = tail.firstIndex(of: 0x0A) {
            tail = tail.suffix(from: tail.index(after: firstNewline))
        } else {
            return
        }
        var tailFramer = JSONLFramer()
        for record in tailFramer.append(tail) {
            try Task.checkCancellation()
            try onRecord(record)
        }
    }
}
