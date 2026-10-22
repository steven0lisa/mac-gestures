import Foundation

// MARK: - 参数与节点定义

struct CLIParam {
    let name: String
    let type: String            // string | integer | number | boolean | enum | array | object
    let required: Bool
    let defaultValue: String?
    let enumValues: [String]?
    let description: String

    init(_ name: String, _ type: String, required: Bool = false,
         default defaultValue: String? = nil, enum values: [String]? = nil,
         description: String) {
        self.name = name
        self.type = type
        self.required = required
        self.defaultValue = defaultValue
        self.enumValues = values
        self.description = description
    }
}

class CLINode: AnyObject {
    let name: String
    var summary: String
    var detailDescription: String?
    weak var parent: CLINode?

    init(name: String, summary: String, description: String? = nil) {
        self.name = name
        self.summary = summary
        self.detailDescription = description
    }

    var path: String {
        var segments: [String] = []
        var node: CLINode? = self
        while let n = node, n.parent != nil {
            segments.insert(n.name, at: 0)
            node = n.parent
        }
        return segments.isEmpty ? "/" : "/" + segments.joined(separator: "/")
    }

    var kind: String { self is CLIGroup ? "group" : "command" }
    var method: String = "GET"
}

final class CLICommand: CLINode {
    let params: [CLIParam]
    let examples: [String]?
    let handler: (CLIContext) throws -> Any

    init(name: String, method: String, summary: String, description: String? = nil,
         params: [CLIParam] = [], examples: [String]? = nil,
         handler: @escaping (CLIContext) throws -> Any) {
        self.params = params
        self.examples = examples
        self.handler = handler
        super.init(name: name, summary: summary, description: description)
        self.method = method
    }
}

final class CLIGroup: CLINode {
    private(set) var children: [CLINode] = []

    func add(_ node: CLINode) {
        node.parent = self
        children.append(node)
    }
}

// MARK: - 上下文与错误

/// 列表命令的返回：items 进 data（参与 fields 投影），meta 合并进信封
struct CLIPage {
    let items: [Any]
    let meta: [String: Any]

    init(items: [Any], meta: [String: Any]) {
        self.items = items
        self.meta = meta
    }
}

struct CLIContext {
    let base: String
    let params: [String: Any]

    func string(_ name: String) -> String? { params[name] as? String }
    func int(_ name: String) -> Int? { params[name] as? Int }
    func double(_ name: String) -> Double? {
        if let d = params[name] as? Double { return d }
        if let i = params[name] as? Int { return Double(i) }
        return nil
    }
    func bool(_ name: String) -> Bool? { params[name] as? Bool }
}

struct CLIError: Error {
    let status: Int
    let code: String
    let message: String
    var hint: String?
    var details: [String: Any]?

    static func invalidParam(_ name: String, _ value: String, hint: String) -> CLIError {
        CLIError(status: 400, code: "invalid_param",
                 message: "parameter \"\(name)\" has invalid value \"\(value)\"", hint: hint)
    }
    static func missing(_ names: [String]) -> CLIError {
        CLIError(status: 400, code: "missing_param",
                 message: "missing required parameter\(names.count > 1 ? "s" : ""): \(names.joined(separator: ", "))",
                 hint: "required: \(names.joined(separator: ", "))")
    }
    static func unknownCommand(_ segments: [String], at parent: CLINode, base: String) -> CLIError {
        let name = segments.first ?? ""
        return CLIError(status: 404, code: "unknown_command",
                        message: "unknown command \"\(name)\" under \(parent.path)",
                        hint: "GET \(base)\(parent.path == "/" ? "" : parent.path)?help=1 to see available subcommands")
    }
}

// MARK: - 路由器：注册表驱动的 help 与分发（http-cli 协议 v1.0.0）

final class CLIRouter {
    let root = CLIGroup(name: "root", summary: "")
    let mountPath: String
    var serverVersion = "0.0.0"
    var authentication: [String: Any] = [:]
    var apiToken: String = ""              // 非空则要求 Authorization: Bearer <token>
    let protocolVersion = "1.0.0"

    var base: String { "http://127.0.0.1:\(port)\(mountPath)" }
    var port: UInt16 = 8741

    init(mountPath: String = "/cli") {
        self.mountPath = mountPath
    }

    // MARK: 入口

    func handle(request: HTTPRequest) -> HTTPResponse {
        // 可选 token 鉴权
        if !apiToken.isEmpty {
            let auth = request.header("authorization") ?? ""
            guard auth == "Bearer \(apiToken)" else {
                let body: [String: Any] = ["error": [
                    "code": "unauthorized",
                    "message": auth.isEmpty ? "missing credential" : "invalid credential",
                    "hint": "send header: Authorization: Bearer <token> (token is set in config.json api_token)",
                ]]
                return .json(401, body, extraHeaders: ["WWW-Authenticate": "Bearer"])
            }
        }

        guard request.path == mountPath || request.path.hasPrefix(mountPath + "/") else {
            return .json(404, ["error": [
                "code": "unknown_command",
                "message": "command tree is mounted at \(mountPath)",
                "hint": "GET \(base)?help=1",
            ]])
        }
        let rest = String(request.path.dropFirst(mountPath.count))
        let segments = rest.split(separator: "/").map(String.init)

        var node: CLINode = root
        for segment in segments {
            guard let group = node as? CLIGroup,
                  let child = group.children.first(where: { $0.name == segment }) else {
                let err = CLIError.unknownCommand([segment], at: node, base: base)
                return errorResponse(err)
            }
            node = child
        }

        // 保留参数解析
        let reserved: Reserved
        do {
            reserved = try parseReservedParams(request.query)
        } catch let error as CLIError {
            return errorResponse(error)
        } catch {
            return errorResponse(CLIError(status: 500, code: "internal_error", message: "unexpected failure"))
        }

        if let group = node as? CLIGroup {
            guard request.method == "GET" else {
                return errorResponse(CLIError(
                    status: 405, code: "method_not_allowed",
                    message: "group \(group.path) only supports GET",
                    hint: "GET \(base)\(group.path)?help=1"))
            }
            return .json(200, ["data": groupHelp(group, detail: reserved.detail)])
        }

        guard let command = node as? CLICommand else {
            return errorResponse(CLIError(status: 500, code: "internal_error", message: "unreachable"))
        }

        if reserved.help {
            return .json(200, ["data": commandHelp(command, detail: reserved.detail)])
        }
        guard request.method == command.method else {
            return errorResponse(CLIError(
                status: 405, code: "method_not_allowed",
                message: "command \(command.path) expects \(command.method), got \(request.method)",
                hint: "use \(command.method) \(base)\(command.path); schema: GET \(base)\(command.path)?help=1"))
        }

        do {
            let merged = try validateParams(command: command, request: request)
            let ctx = CLIContext(base: base, params: merged)
            let raw = try command.handler(ctx)
            let requestId = UUID().uuidString
            if let page = raw as? CLIPage {
                let projected = reserved.fields.map { Self.project(page.items, fields: $0) } ?? page.items
                var meta = page.meta
                meta["request_id"] = requestId
                return .json(200, ["data": projected, "meta": meta])
            }
            let projected = reserved.fields.map { Self.project(raw, fields: $0) } ?? raw
            return .json(200, ["data": projected, "meta": ["request_id": requestId]])
        } catch let error as CLIError {
            return errorResponse(error)
        } catch {
            return errorResponse(CLIError(status: 500, code: "internal_error",
                                          message: "unexpected failure"))
        }
    }

    private func errorResponse(_ error: CLIError) -> HTTPResponse {
        var body: [String: Any] = ["code": error.code, "message": error.message]
        if let hint = error.hint { body["hint"] = hint }
        if let details = error.details { body["details"] = details }
        return .json(error.status, ["error": body])
    }

    // MARK: - 保留参数

    private struct Reserved {
        var help = false
        var detail = false
        var fields: [String]?
    }

    private func parseReservedParams(_ query: [String: String]) throws -> Reserved {
        var result = Reserved()
        if let raw = query["help"] {
            switch raw.lowercased() {
            case "", "1", "true": result.help = true
            case "0", "false": result.help = false
            default: throw CLIError.invalidParam("help", raw, hint: "use help=1")
            }
        }
        if let raw = query["detail"] {
            switch raw.lowercased() {
            case "1", "true": result.detail = true
            case "0", "false", "": result.detail = false
            default: throw CLIError.invalidParam("detail", raw, hint: "use detail=1")
            }
        }
        if let raw = query["fields"] {
            let names = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            result.fields = names.filter { !$0.isEmpty }
        }
        return result
    }

    // MARK: - 参数校验（query 字符串按声明类型强转；body 原生类型；body 优先）

    private func validateParams(command: CLICommand, request: HTTPRequest) throws -> [String: Any] {
        var merged: [String: Any] = [:]
        let declared = command.params
        let declaredNames = Set(declared.map(\.name))
        let reservedNames: Set<String> = ["help", "fields", "detail"]

        // body
        var bodyObject: [String: Any] = [:]
        let bodyCarrying = ["POST", "PUT", "PATCH", "DELETE"].contains(command.method)
        if bodyCarrying, !request.body.isEmpty {
            let contentType = request.header("content-type") ?? ""
            guard contentType.lowercased().contains("application/json") else {
                throw CLIError(status: 415, code: "unsupported_media_type",
                               message: "request body must be application/json",
                               hint: "set header Content-Type: application/json")
            }
            guard let parsed = try? JSONSerialization.jsonObject(with: request.body),
                  let object = parsed as? [String: Any] else {
                throw CLIError(status: 400, code: "bad_body",
                               message: "request body is not a valid JSON object",
                               hint: "send a JSON object, e.g. {\"id\": \"ok\"}")
            }
            bodyObject = object
        }

        // 未知参数拒绝（提示最接近的已声明参数）
        let unknownNames = Set(bodyObject.keys).union(request.query.keys).subtracting(declaredNames).subtracting(reservedNames)
        if let first = unknownNames.sorted().first {
            let closest = declared.map(\.name).min { levenshtein($0, first) < levenshtein($1, first) }
            let hint = closest.map { "did you mean \"\($0)\"? declared parameters: \(declaredNames.sorted().joined(separator: ", "))" }
                ?? "declared parameters: \(declaredNames.sorted().joined(separator: ", "))"
            throw CLIError(status: 400, code: "invalid_param",
                           message: "unknown parameter \"\(first)\"", hint: hint,
                           details: ["parameter": first])
        }

        // query 字符串强转
        for param in declared {
            if let raw = request.query[param.name] {
                merged[param.name] = try Self.coerce(raw, to: param, from: "query")
            }
        }
        // body 原生类型（覆盖同名 query 值）
        for param in declared {
            if let value = bodyObject[param.name] {
                merged[param.name] = try Self.checkNative(value, param: param)
            }
        }
        // 必填检查
        let missing = declared.filter { $0.required && merged[$0.name] == nil }.map(\.name)
        if !missing.isEmpty { throw CLIError.missing(missing) }
        return merged
    }

    static func coerce(_ raw: String, to param: CLIParam, from source: String) throws -> Any {
        switch param.type {
        case "string":
            return raw
        case "integer":
            guard let value = Int(raw) else {
                throw CLIError.invalidParam(param.name, raw, hint: "expected integer for \(source) parameter \"\(param.name)\"")
            }
            return value
        case "number":
            guard let value = Double(raw) else {
                throw CLIError.invalidParam(param.name, raw, hint: "expected number for \(source) parameter \"\(param.name)\"")
            }
            return value
        case "boolean":
            switch raw.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default:
                throw CLIError.invalidParam(param.name, raw, hint: "expected boolean (true/false) for \(source) parameter \"\(param.name)\"")
            }
        case "enum":
            if let allowed = param.enumValues, allowed.contains(raw) { return raw }
            throw CLIError.invalidParam(param.name, raw,
                                        hint: "allowed: \((param.enumValues ?? []).joined(separator: " | "))")
        default:
            // array/object 不支持 query 字符串形式
            throw CLIError.invalidParam(param.name, raw,
                                        hint: "parameter \"\(param.name)\" of type \(param.type) must be sent in the JSON body")
        }
    }

    static func checkNative(_ value: Any, param: CLIParam) throws -> Any {
        switch param.type {
        case "string":
            if let s = value as? String { return s }
        case "integer":
            if let i = value as? Int { return i }
            if let d = value as? Double, d == d.rounded() { return Int(d) }
        case "number":
            if let d = value as? Double { return d }
            if let i = value as? Int { return Double(i) }
        case "boolean":
            if let b = value as? Bool { return b }
        case "enum":
            if let s = value as? String, let allowed = param.enumValues, allowed.contains(s) { return s }
            if let s = value as? String {
                throw CLIError.invalidParam(param.name, s,
                                            hint: "allowed: \((param.enumValues ?? []).joined(separator: " | "))")
            }
        case "array":
            if value is [Any] { return value }
        case "object":
            if value is [String: Any] { return value }
        default:
            break
        }
        throw CLIError(status: 400, code: "invalid_param",
                       message: "parameter \"\(param.name)\" must be of type \(param.type)",
                       hint: "send a native JSON \(param.type) value in the request body")
    }

    // MARK: - help 文档（与注册表同源）

    private func childEntry(_ node: CLINode) -> [String: Any] {
        [
            "kind": node.kind,
            "name": node.name,
            "path": node.path,
            "method": node.method,
            "summary": node.summary,
        ]
    }

    func groupHelp(_ group: CLIGroup, detail: Bool) -> [String: Any] {
        var doc: [String: Any] = [
            "kind": "group",
            "path": group.path,
            "name": group.name,
            "method": "GET",
            "summary": group.summary,
            "subcommands": group.children.map(childEntry),
            "usage": "GET \(base)\(group.path == "/" ? "" : group.path)/<command>?help=1",
        ]
        if detail, let description = group.detailDescription {
            doc["description"] = description
        }
        if group === root {
            doc["protocol_version"] = protocolVersion
            doc["server_version"] = serverVersion
            doc["authentication"] = authentication
        }
        return doc
    }

    func commandHelp(_ command: CLICommand, detail: Bool) -> [String: Any] {
        var doc: [String: Any] = [
            "kind": "command",
            "path": command.path,
            "name": command.name,
            "method": command.method,
            "summary": command.summary,
            "params": command.params.map { param -> [String: Any] in
                var p: [String: Any] = [
                    "name": param.name,
                    "type": param.type,
                    "required": param.required,
                    "description": param.description,
                ]
                if let enumValues = param.enumValues { p["enum"] = enumValues }
                if let defaultValue = param.defaultValue { p["default"] = defaultValue }
                return p
            },
            "usage": "\(command.method) \(base)\(command.path)",
        ]
        if detail {
            if let description = command.detailDescription { doc["description"] = description }
            if let examples = command.examples { doc["examples"] = examples }
        }
        return doc
    }

    // MARK: - fields 投影

    static func project(_ data: Any, fields: [String]) -> Any {
        let wanted = Set(fields)
        if let dict = data as? [String: Any] {
            return dict.filter { wanted.contains($0.key) }
        }
        if let array = data as? [[String: Any]] {
            return array.map { $0.filter { wanted.contains($0.key) } }
        }
        if let array = data as? [Any] {
            return array.map { project($0, fields: fields) }
        }
        return data
    }

    // MARK: - 杂项

    private func levenshtein(_ a: String, _ b: String) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var matrix = Array(repeating: Array(0...b.count), count: a.count + 1)
        for (i, ca) in a.enumerated() {
            for (j, cb) in b.enumerated() {
                let cost = ca == cb ? 0 : 1
                matrix[i + 1][j + 1] = min(matrix[i][j + 1] + 1, matrix[i + 1][j] + 1, matrix[i][j] + cost)
            }
        }
        return matrix[a.count][b.count]
    }
}
