import Foundation

struct RawHTTPResponse {
    let status: Int
    let headers: [String: String] // lowercased keys
    let body: Data
}

enum HTTPWireFormat {
    static func buildRequest(method: String, path: String, headers: [String: String], body: Data?) -> Data {
        var allHeaders = headers
        allHeaders["Connection"] = allHeaders["Connection"] ?? "close"
        if let body {
            allHeaders["Content-Length"] = "\(body.count)"
            if allHeaders["Content-Type"] == nil { allHeaders["Content-Type"] = "application/json" }
        }

        var head = "\(method) \(path) HTTP/1.1\r\n"
        for (key, value) in allHeaders { head += "\(key): \(value)\r\n" }
        head += "\r\n"

        var data = Data(head.utf8)
        if let body { data.append(body) }
        return data
    }

    /// Parses a response from bytes read up to connection close (this client always sends
    /// `Connection: close`, so EOF marks the end of the body — no chunked-encoding support is
    /// needed on either side of this API).
    static func parseResponse(_ raw: Data) throws -> RawHTTPResponse {
        guard let boundary = raw.range(of: Data("\r\n\r\n".utf8)) else {
            throw PiDeskClientError.invalidResponse("response had no header terminator")
        }
        guard let headerText = String(data: raw[..<boundary.lowerBound], encoding: .utf8) else {
            throw PiDeskClientError.invalidResponse("response headers were not valid UTF-8")
        }
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw PiDeskClientError.invalidResponse("response had no status line") }
        let statusLine = lines.removeFirst()
        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else {
            throw PiDeskClientError.invalidResponse("could not parse status line \"\(statusLine)\"")
        }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let bodyBytes = raw[boundary.upperBound...]
        if let declared = headers["content-length"] {
            guard let length = Int(declared), length >= 0 else {
                throw PiDeskClientError.invalidResponse("response had an invalid Content-Length")
            }
            guard bodyBytes.count == length else {
                throw PiDeskClientError.invalidResponse(
                    "response contained \(bodyBytes.count) bytes but declared \(length)"
                )
            }
            return RawHTTPResponse(status: status, headers: headers, body: Data(bodyBytes))
        }
        return RawHTTPResponse(status: status, headers: headers, body: Data(bodyBytes))
    }

    /// Splits off the status line + headers from a streaming connection (SSE), returning the
    /// parsed head and whatever body bytes already arrived in the same read.
    static func splitHeadFromStream(_ raw: Data) -> (head: RawHTTPResponse, leftover: Data)? {
        guard let boundary = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let response = try? parseResponse(Data(raw[..<boundary.upperBound])) else { return nil }
        return (response, Data(raw[boundary.upperBound...]))
    }
}
