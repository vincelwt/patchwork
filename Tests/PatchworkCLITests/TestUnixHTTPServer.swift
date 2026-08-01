import Darwin
import Foundation

/// A minimal scripted HTTP/1.1 server over a Unix domain socket, used only to prove
/// `RawHTTPClient` parses real bytes correctly. This is a hermetic in-process test double built
/// from the same POSIX primitives as the production client — never a real `patchworkd` — so
/// exercising it does not violate "never talk to a real daemon in tests".
final class TestUnixHTTPServer {
    let socketPath: String
    private var listenFd: Int32 = -1
    private let stateLock = NSLock()
    private let queue = DispatchQueue(label: "patchwork-test-unix-http-server")

    init() {
        // `sockaddr_un.sun_path` is only 104 bytes on Darwin. NSTemporaryDirectory can already
        // consume most of that budget, so keep the generated leaf deliberately short.
        socketPath = NSTemporaryDirectory() + "pw-\(UUID().uuidString).sock"
    }

    enum ServerError: Error { case socketFailed, bindFailed, listenFailed }

    /// Accepts connections one at a time (`maxRequests` of them) in the background. `respond` gets
    /// the raw request text (headers, plus any body already read per Content-Length) and returns
    /// the exact bytes to write back.
    func start(maxRequests: Int = 1, writeInChunks: Bool = false, respond: @escaping (String) -> Data) throws {
        listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFd >= 0 else { throw ServerError.socketFailed }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { charPtr in
                for (index, byte) in bytes.enumerated() { charPtr[index] = CChar(bitPattern: byte) }
                charPtr[bytes.count] = 0
            }
        }
        let bound = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(listenFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw ServerError.bindFailed }
        guard listen(listenFd, 4) == 0 else { throw ServerError.listenFailed }

        let fd = listenFd
        queue.async { [self] in
            for _ in 0..<maxRequests {
                let clientFd = accept(fd, nil, nil)
                guard clientFd >= 0 else { return }
                handleOneRequest(clientFd, writeInChunks: writeInChunks, respond: respond)
                close(clientFd)
            }
            closeListener(fd)
        }
    }

    private func closeListener(_ fd: Int32) {
        let shouldClose = stateLock.withLock { () -> Bool in
            guard listenFd == fd else { return false }
            listenFd = -1
            return true
        }
        guard shouldClose else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func handleOneRequest(_ clientFd: Int32, writeInChunks: Bool, respond: (String) -> Data) {
        var requestBytes = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while requestBytes.range(of: Data("\r\n\r\n".utf8)) == nil {
            let n = read(clientFd, &buffer, buffer.count)
            guard n > 0 else { return }
            requestBytes.append(contentsOf: buffer[0..<n])
        }
        let requestText = String(decoding: requestBytes, as: UTF8.self)
        let response = respond(requestText)
        if writeInChunks {
            // Splits the write to prove the client reassembles lines/bodies across read() calls,
            // not just when everything arrives in one packet.
            let mid = response.count / 2
            writeAll(clientFd, response.prefix(mid))
            usleep(20_000)
            writeAll(clientFd, response.suffix(from: mid))
        } else {
            writeAll(clientFd, response)
        }
    }

    private func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base.advanced(by: offset), raw.count - offset)
                guard n > 0 else { return }
                offset += n
            }
        }
    }

    func stop() {
        let fd = stateLock.withLock { () -> Int32 in
            let current = listenFd
            listenFd = -1
            return current
        }
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    static func httpResponse(status: String = "200 OK", headers: [String: String] = [:], body: Data) -> Data {
        var head = "HTTP/1.1 \(status)\r\n"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        if headers.keys.contains(where: { $0.lowercased() == "content-length" }) == false,
           headers.keys.contains(where: { $0.lowercased() == "transfer-encoding" }) == false {
            head += "Content-Length: \(body.count)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}
