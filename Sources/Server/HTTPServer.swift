import Foundation

// MARK: - HTTP 请求/响应模型

struct HTTPRequest {
    var method: String
    var path: String                  // 已解码，如 "/cli/gestures/list"
    var query: [String: String]       // 已解码（+ 不转空格，按 RFC 3986）
    var headers: [String: String]     // key 小写
    var body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

struct HTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: Data

    static let reasonPhrases: [Int: String] = [
        200: "OK", 204: "No Content", 301: "Moved Permanently", 308: "Permanent Redirect",
        400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
        405: "Method Not Allowed", 409: "Conflict", 413: "Payload Too Large",
        415: "Unsupported Media Type", 429: "Too Many Requests", 500: "Internal Server Error",
    ]

    static func json(_ status: Int, _ object: [String: Any],
                     extraHeaders: [String: String] = [:]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        var headers = ["Content-Type": "application/json; charset=utf-8"]
        headers.merge(extraHeaders) { _, new in new }
        return HTTPResponse(status: status, headers: headers, body: data)
    }

    static func html(_ status: Int, _ html: String) -> HTTPResponse {
        HTTPResponse(status: status,
                     headers: ["Content-Type": "text/html; charset=utf-8"],
                     body: Data(html.utf8))
    }
}

// MARK: - 极简 HTTP/1.1 服务器（POSIX socket，仅绑定 127.0.0.1）

final class HTTPServer {
    typealias Handler = (HTTPRequest) -> HTTPResponse

    let port: UInt16
    let handler: Handler
    private var listenFD: Int32 = -1
    private var stopped = false
    private let workerQueue = DispatchQueue(label: "com.macgestures.http.worker", attributes: .concurrent)

    static let maxBodySize = 1_000_000       // 1 MB
    private static let maxHeaderSize = 32_768
    private static let ioTimeoutSeconds: Int32 = 15

    init(port: UInt16, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    /// 同步绑定 + 监听（端口占用等错误在这里直接抛出），accept 循环跑在独立线程
    func start() throws {
        // 1. socket
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socket(errno) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // 2. bind 127.0.0.1:port（内核级只允许回环访问）
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw ServerError.bind(port, errno)
        }

        // 3. listen
        guard listen(fd, 64) == 0 else {
            close(fd)
            throw ServerError.listen(errno)
        }

        listenFD = fd
        stopped = false
        Thread.detachNewThread { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        stopped = true
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
    }

    enum ServerError: LocalizedError {
        case socket(Int32)
        case bind(UInt16, Int32)
        case listen(Int32)

        var errorDescription: String? {
            switch self {
            case .socket: return "创建 socket 失败 (errno \(errno))"
            case .bind(let port, let e):
                if e == 98 || e == 48 { return "端口 \(port) 已被占用" }
                return "绑定 127.0.0.1:\(port) 失败 (errno \(e))"
            case .listen: return "listen 失败 (errno \(errno))"
            }
        }
    }

    // MARK: - accept 循环（独立线程）

    private func acceptLoop() {
        while !stopped {
            var addr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFD = accept(listenFD, &addr, &len)
            if clientFD < 0 {
                if stopped { return }
                if errno == EINTR { continue }
                usleep(50_000)
                continue
            }
            workerQueue.async { [weak self] in
                self?.serve(clientFD: clientFD)
            }
        }
    }

    /// 单连接处理：收完整请求 → 执行 handler → 回复 → 关闭
    private func serve(clientFD: Int32) {
        defer { close(clientFD) }

        // 读超时，防止客户端挂住占线程
        var timeout = timeval(tv_sec: time_t(Self.ioTimeoutSeconds), tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard let request = readRequest(clientFD: clientFD) else {
            let response = HTTPResponse.json(400, ["error": ["code": "bad_body",
                                                             "message": "malformed HTTP request"]])
            writeAll(clientFD, data: serialize(response))
            return
        }

        // 请求体超限提前拒绝
        if let declared = request.declaredContentLength, declared > Self.maxBodySize {
            writeAll(clientFD, data: serialize(.json(413, ["error": [
                "code": "payload_too_large",
                "message": "请求体 \(declared) 字节超过上限 \(Self.maxBodySize)",
                "hint": "压缩或精简请求体",
            ]])))
            return
        }
        guard let parsed = request.parse() else {
            writeAll(clientFD, data: serialize(.json(400, ["error": [
                "code": "bad_body", "message": "malformed HTTP request line",
            ]])))
            return
        }
        if parsed.body.count > Self.maxBodySize {
            writeAll(clientFD, data: serialize(.json(413, ["error": [
                "code": "payload_too_large",
                "message": "请求体超过上限 \(Self.maxBodySize) 字节",
            ]])))
            return
        }

        let response = handler(parsed)
        writeAll(clientFD, data: serialize(response))
    }

    // MARK: - 读请求

    private final class RequestBuffer {
        var data = Data()
        var headerEnd: Data.Index?
        var contentLength: Int?

        var declaredContentLength: Int? { contentLength }

        var hasFullHeader: Bool {
            if headerEnd == nil, let range = data.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = range.upperBound
                contentLength = Self.contentLength(from: data[..<range.lowerBound])
            }
            return headerEnd != nil
        }

        var isComplete: Bool {
            guard hasFullHeader, let end = headerEnd else { return false }
            let headLength = data.distance(from: data.startIndex, to: end)
            return data.count >= headLength + (contentLength ?? 0)
        }

        var headerBytesExceeded: Bool { data.count > 32_768 && !hasFullHeader }

        func parse() -> HTTPRequest? {
            guard let end = headerEnd else { return nil }
            let headText = String(decoding: data[..<data.index(end, offsetBy: -4)], as: UTF8.self)
            var bodyData = Data()
            if let cl = contentLength, cl > 0 {
                let bodyStart = end
                let bodyEnd = data.index(bodyStart, offsetBy: min(cl, data.count - bodyStart))
                bodyData = Data(data[bodyStart..<bodyEnd])
            }

            var lines = headText.components(separatedBy: "\r\n")
            guard !lines.isEmpty else { return nil }
            let requestLine = lines.removeFirst()
            let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { return nil }
            let method = String(parts[0]).uppercased()
            let target = String(parts[1])

            var path = target
            var queryString = ""
            if let q = target.firstIndex(of: "?") {
                path = String(target[target.startIndex..<q])
                queryString = String(target[target.index(after: q)...])
            }

            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }

            var query: [String: String] = [:]
            if !queryString.isEmpty {
                for pair in queryString.split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    let key = Self.percentDecode(String(kv[0]))
                    let value = kv.count > 1 ? Self.percentDecode(String(kv[1])) : ""
                    if !key.isEmpty { query[key] = value }
                }
            }

            let decodedPath = path.split(separator: "/", omittingEmptySubsequences: true)
                .map { Self.percentDecode(String($0)) }
                .joined(separator: "/")

            return HTTPRequest(method: method, path: "/" + decodedPath, query: query,
                               headers: headers, body: bodyData)
        }

        static func contentLength(from headerBlock: Data) -> Int? {
            let text = String(decoding: headerBlock, as: UTF8.self)
            for line in text.components(separatedBy: "\r\n") {
                let lower = line.lowercased()
                if lower.hasPrefix("content-length:") {
                    return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
                }
            }
            return 0
        }

        static func percentDecode(_ string: String) -> String {
            var bytes: [UInt8] = []
            let utf8 = Array(string.utf8)
            var i = 0
            while i < utf8.count {
                if utf8[i] == UInt8(ascii: "%"), i + 2 < utf8.count,
                   let hi = hexValue(utf8[i + 1]), let lo = hexValue(utf8[i + 2]) {
                    bytes.append(hi << 4 | lo)
                    i += 3
                } else {
                    bytes.append(utf8[i])
                    i += 1
                }
            }
            return String(decoding: bytes, as: UTF8.self)
        }

        private static func hexValue(_ c: UInt8) -> UInt8? {
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
            default: return nil
            }
        }
    }

    private func readRequest(clientFD: Int32) -> RequestBuffer? {
        let buffer = RequestBuffer()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while !stopped {
            let n = recv(clientFD, &chunk, chunk.count, 0)
            if n <= 0 { return nil }
            buffer.data.append(contentsOf: chunk[0..<n])
            if buffer.headerBytesExceeded { return nil }
            if buffer.isComplete { return buffer }
        }
        return nil
    }

    // MARK: - 回写

    private func serialize(_ response: HTTPResponse) -> Data {
        var head = "HTTP/1.1 \(response.status) \(HTTPResponse.reasonPhrases[response.status] ?? "OK")\r\n"
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = "close"
        headers["X-HTTP-CLI-Version"] = "1.0.0"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(response.body)
        return payload
    }

    @discardableResult
    private func writeAll(_ fd: Int32, data: Data) -> Bool {
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let n = bytes.withUnsafeBufferPointer { buffer in
                send(fd, buffer.baseAddress! + offset, bytes.count - offset, 0)
            }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
}
