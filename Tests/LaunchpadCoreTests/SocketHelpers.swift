import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A one-line server on 127.0.0.1: reads "ping", answers "pong", hangs up.
final class EchoServer: @unchecked Sendable {
    let fd: Int32
    let port: UInt16

    init() throws {
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0, listen(fd, 8) == 0 else { throw CocoaError(.fileWriteUnknown) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        self.fd = fd
        port = UInt16(bigEndian: addr.sin_port)
        let listener = fd
        Thread.detachNewThread {
            while true {
                let c = accept(listener, nil, nil)
                if c < 0 { return }
                var buf = [UInt8](repeating: 0, count: 4)
                var got = 0
                while got < 4 {
                    let n = buf.withUnsafeMutableBytes { recv(c, $0.baseAddress! + got, 4 - got, 0) }
                    if n <= 0 { break }
                    got += n
                }
                _ = "pong".withCString { send(c, $0, 4, 0) }
                close(c)
            }
        }
    }

    func stop() {
        shutdown(fd, Int32(SHUT_RDWR))
        close(fd)
    }
}

enum TestSocket {
    /// Connects to 127.0.0.1:port, sends `text`, and reads everything until the other side hangs up (5 s at most).
    static func exchange(port: UInt16, _ text: String) throws -> String {
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        defer { close(fd) }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { throw CocoaError(.fileReadUnknown) }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress!, bytes.count, 0) }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return String(decoding: out, as: UTF8.self)
    }
}
