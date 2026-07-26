import Foundation

/// One `event:`/`data:` block from an SSE stream, terminated by a blank line. `: keep-alive`
/// comment lines carry no event name and are dropped by the parser rather than surfaced.
struct SSEFrame {
    var event: String?
    var data: String
}

/// Accumulates raw bytes from a long-lived `GET /v1/events` connection into complete frames.
/// Line-oriented and tolerant of a frame split across multiple socket reads.
struct SSEParser {
    private var buffer = ""
    private var pendingEvent: String?
    private var pendingData: [String] = []

    mutating func append(_ chunk: Data) -> [SSEFrame] {
        guard let text = String(data: chunk, encoding: .utf8) else { return [] }
        buffer += text

        var frames: [SSEFrame] = []
        while let newlineRange = buffer.range(of: "\n") {
            var line = String(buffer[buffer.startIndex..<newlineRange.lowerBound])
            buffer.removeSubrange(buffer.startIndex..<newlineRange.upperBound)
            if line.hasSuffix("\r") { line.removeLast() }

            if line.isEmpty {
                if !pendingData.isEmpty || pendingEvent != nil {
                    frames.append(SSEFrame(event: pendingEvent, data: pendingData.joined(separator: "\n")))
                }
                pendingEvent = nil
                pendingData = []
                continue
            }
            if line.hasPrefix(":") { continue } // comment / keep-alive
            if let range = line.range(of: ":") {
                let field = String(line[line.startIndex..<range.lowerBound])
                var value = String(line[range.upperBound...])
                if value.hasPrefix(" ") { value.removeFirst() }
                switch field {
                case "event": pendingEvent = value
                case "data": pendingData.append(value)
                default: break // "id"/"retry" are not part of this API's contract; ignored
                }
            }
        }
        return frames
    }
}

extension SSEFrame {
    /// Decodes this frame into the typed event the doc defines for its `event:` name, or
    /// `.unknown` for anything this build does not recognise — the SSE half of the same
    /// forward-compatibility rule every other decode in this package follows.
    func decodedEvent() -> PiDeskEvent {
        guard let event, let payload = data.data(using: .utf8) else {
            return .unknown(name: event ?? "", data: (try? PiJSONValue.decode(Data(data.utf8))) ?? .null)
        }
        do {
            switch event {
            case "thread": return .thread(try PiDeskJSON.decoder.decode(PiThread.self, from: payload))
            case "activity": return .activity(try PiDeskJSON.decoder.decode(ActivitySnapshot.self, from: payload))
            case "run": return .run(try PiDeskJSON.decoder.decode(Run.self, from: payload))
            case "schedule": return .schedule(try PiDeskJSON.decoder.decode(Schedule.self, from: payload))
            default:
                let value = (try? PiJSONValue.decode(payload)) ?? .null
                return .unknown(name: event, data: value)
            }
        } catch {
            // A malformed payload for a *known* event name still must not crash the consumer;
            // fall through to unknown with whatever raw JSON could be salvaged.
            let value = (try? PiJSONValue.decode(payload)) ?? .string(data)
            return .unknown(name: event, data: value)
        }
    }
}
