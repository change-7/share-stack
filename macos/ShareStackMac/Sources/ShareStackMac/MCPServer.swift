import CoreFoundation
import Foundation

final class MCPServer {
    private var initialized = false
    private var negotiated = false

    private struct Tool {
        let name: String
        let description: String
        let properties: [String: Any]
        var required: [String] = []
        var readOnly = true
        var destructive = false
        var idempotent = true
        var openWorld = false

        var definition: [String: Any] {
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
             "annotations": ["readOnlyHint": readOnly, "destructiveHint": destructive,
                             "idempotentHint": idempotent, "openWorldHint": openWorld]]
        }
    }

    private static let uuid: [String: Any] = ["type": "string", "format": "uuid", "minLength": 36, "maxLength": 36]
    private static let ids: [String: Any] = ["type": "array", "minItems": 1, "maxItems": 100, "items": uuid]
    private static let paging: [String: Any] = [
        "limit": ["type": "integer", "minimum": 1, "maximum": 100, "description": "Page size; default 50."],
        "offset": ["type": "integer", "minimum": 0, "maximum": 1000000, "description": "Zero-based offset; default 0."]
    ]
    private static let tools: [Tool] = [
        Tool(name: "list_shared_files", description: "List only files explicitly copied into ShareStack AI Exchange. Returns registered file IDs, names, sizes and extensions.", properties: paging),
        Tool(name: "get_shared_file_info", description: "Read metadata for a file registered in AI Exchange. Other ShareStack inbox files and Mac paths are not visible.", properties: ["id": uuid], required: ["id"]),
        Tool(name: "read_shared_file", description: "Read UTF-8 text from a registered AI Exchange file in byte-offset chunks up to 32 KiB. UTF-8 characters are not split.", properties: ["id": uuid, "offset": ["type": "integer", "minimum": 0, "maximum": 21474836480], "limit": ["type": "integer", "minimum": 4, "maximum": 32768]], required: ["id"]),
        Tool(name: "receive_exchange_text_file", description: "Create a new UTF-8 text file in AI Exchange from supplied content. No Mac path is read. SHA-256 is calculated and verified; maximum content size is 128 KiB.", properties: ["filename": ["type": "string", "minLength": 1, "maxLength": 1024], "content": ["type": "string", "maxLength": 131072]], required: ["filename", "content"], readOnly: false, idempotent: false),
        Tool(name: "receive_text_file", description: "Receive a small UTF-8 text file from supplied content; no Mac path or download link is read. Receive settings choose inbox or automatic save. SHA-256 is checked, duplicate content is deduplicated, and filename collisions are renamed when saved. Max 128 KiB of UTF-8 content.", properties: ["filename": ["type": "string", "minLength": 1, "maxLength": 1024], "content": ["type": "string", "maxLength": 131072]], required: ["filename", "content"], readOnly: false, idempotent: false),
        Tool(name: "get_job", description: "Read the status of a text-receive job created by this AI connection.", properties: ["id": uuid], required: ["id"]),
        Tool(name: "cancel_job", description: "Cancel a text-receive job created by this AI connection.", properties: ["id": uuid], required: ["id"], readOnly: false)
    ]

    func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            autoreleasepool {
                var identifier: Any = NSNull()
                do {
                    guard line.utf8.count <= 1024 * 1024 else { throw RPCError(code: -32600, message: "Request exceeds 1 MiB") }
                    let object: Any
                    do { object = try JSONSerialization.jsonObject(with: Data(line.utf8)) }
                    catch { throw RPCError(code: -32700, message: "Parse error") }
                    guard let request = object as? [String: Any], request["jsonrpc"] as? String == "2.0",
                          let method = request["method"] as? String else { throw RPCError(code: -32600, message: "Invalid request") }
                    if let id = request["id"] {
                        guard id is String || (id as? NSNumber).map({ CFGetTypeID($0) != CFBooleanGetTypeID() }) == true else {
                            throw RPCError(code: -32600, message: "Invalid request id")
                        }
                        identifier = id
                    } else {
                        if method == "notifications/initialized", negotiated { initialized = true }
                        return
                    }
                    guard request["params"] == nil || request["params"] is [String: Any] else { throw RPCError(code: -32602, message: "Invalid params") }
                    let params = request["params"] as? [String: Any] ?? [:]
                    let result: [String: Any]
                    switch method {
                    case "initialize":
                        guard !negotiated, let version = params["protocolVersion"] as? String else { throw RPCError(code: -32602, message: "Invalid initialization") }
                        negotiated = true
                        let versions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
                        result = ["protocolVersion": versions.contains(version) ? version : "2025-06-18",
                                  "capabilities": ["tools": ["listChanged": false]],
                                  "serverInfo": ["name": "share_stack", "version": "1.0.0"]]
                    case "ping": result = [:]
                    case "tools/list":
                        guard initialized else { throw RPCError(code: -32002, message: "Initialize first") }
                        let cursor = params["cursor"] as? String ?? "0"
                        guard params["cursor"] == nil || params["cursor"] is String,
                              let offset = Int(cursor), offset >= 0, offset < Self.tools.count else { throw RPCError(code: -32602, message: "Invalid tools cursor") }
                        let end = min(offset + 7, Self.tools.count)
                        var page: [String: Any] = ["tools": Self.tools[offset..<end].map(\.definition)]
                        if end < Self.tools.count { page["nextCursor"] = String(end) }
                        result = page
                    case "tools/call":
                        guard initialized else { throw RPCError(code: -32002, message: "Initialize first") }
                        guard let name = params["name"] as? String, let tool = Self.tools.first(where: { $0.name == name }),
                              params["arguments"] == nil || params["arguments"] is [String: Any] else { throw RPCError(code: -32602, message: "Unknown tool or invalid arguments") }
                        let arguments = params["arguments"] as? [String: Any] ?? [:]
                        try Self.validate(arguments, schema: tool.definition["inputSchema"] as! [String: Any])
                        if name == "list_events", (arguments["after"] == nil) != (arguments["streamID"] == nil) {
                            throw RPCError(code: -32602, message: "after and streamID must be supplied together")
                        }
                        do {
                            let deadline = Date().addingTimeInterval(8)
                            try GUIBridge.ensureReady(until: deadline)
                            let value = try call(name, arguments: arguments, deadline: deadline)
                            let structured = value as? [String: Any] ?? ["items": value]
                            result = ["content": [["type": "text", "text": String(decoding: try JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]), as: UTF8.self)]],
                                      "structuredContent": structured, "isError": false]
                        } catch {
                            result = ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
                        }
                    default: throw RPCError(code: -32601, message: "Method not found")
                    }
                    write(["jsonrpc": "2.0", "id": identifier, "result": result])
                } catch let error as RPCError {
                    write(["jsonrpc": "2.0", "id": identifier, "error": ["code": error.code, "message": error.message]])
                } catch {
                    write(["jsonrpc": "2.0", "id": identifier, "error": ["code": -32603, "message": "Internal error"]])
                }
            }
        }
    }

    private func call(_ name: String, arguments: [String: Any], deadline: Date) throws -> Any {
        func request(_ method: String, _ path: String, body: Any? = nil) throws -> Any {
            try GUIBridge.request(method, path: path, body: body, timeout: max(0, deadline.timeIntervalSinceNow))
        }
        let limit = arguments["limit"] as? Int ?? 50
        let offset = arguments["offset"] as? Int ?? 0
        func page(_ items: [Any]) -> [String: Any] {
            let selected = Array(items.dropFirst(offset).prefix(limit))
            var value: [String: Any] = ["items": selected]
            if offset + selected.count < items.count { value["nextOffset"] = offset + selected.count }
            return value
        }
        switch name {
        case "get_status": return try request("GET", "/v1/status")
        case "list_shared_files":
            var components = URLComponents()
            components.path = "/v1/shared-files"
            components.queryItems = [.init(name: "limit", value: String(limit)), .init(name: "offset", value: String(offset))]
            return try request("GET", components.string!)
        case "get_shared_file_info": return try request("GET", "/v1/shared-files/" + (arguments["id"] as! String))
        case "read_shared_file":
            var components = URLComponents()
            components.path = "/v1/shared-files/" + (arguments["id"] as! String) + "/content"
            components.queryItems = [
                .init(name: "offset", value: String(arguments["offset"] as? Int ?? 0)),
                .init(name: "limit", value: String(arguments["limit"] as? Int ?? 4096))
            ]
            return try request("GET", components.string!)
        case "get_item": return try request("GET", "/v1/items/" + (arguments["id"] as! String))
        case "get_job": return try request("GET", "/v1/jobs/" + (arguments["id"] as! String))
        case "cancel_job": return try request("POST", "/v1/jobs/" + (arguments["id"] as! String) + "/cancel")
        case "receive_exchange_text_file":
            return try request("POST", "/v1/ai-exchange/text", body: [
                "filename": arguments["filename"] as! String,
                "content": arguments["content"] as! String
            ])
        case "list_inbox", "list_outbox":
            return page(try request("GET", name == "list_inbox" ? "/v1/inbox" : "/v1/pending") as? [Any] ?? [])
        case "list_events":
            var components = URLComponents()
            components.path = "/v1/events"
            if let after = arguments["after"] as? Int, let stream = arguments["streamID"] as? String {
                components.queryItems = [.init(name: "after", value: String(after)), .init(name: "streamID", value: stream)]
            }
            return try request("GET", components.string!)
        default:
            let operations = ["receive_text_file": "receiveTextFile"]
            guard let operation = operations[name] else { throw RPCError(code: -32602, message: "Unknown tool") }
            var payload: [String: Any] = ["operation": operation]
            if let ids = arguments["ids"] { payload["itemIDs"] = ids }
            if let paths = arguments["paths"] { payload["filePaths"] = paths }
            if let text = arguments["text"] { payload["text"] = text }
            if let filename = arguments["filename"] { payload["filename"] = filename }
            if let content = arguments["content"] { payload["content"] = content }
            return try request("POST", "/v1/jobs", body: payload)
        }
    }

    private static func validate(_ value: Any, schema: [String: Any]) throws {
        func invalid() -> RPCError { RPCError(code: -32602, message: "Arguments do not match inputSchema") }
        switch schema["type"] as? String {
        case "object":
            guard let object = value as? [String: Any], let properties = schema["properties"] as? [String: Any],
                  Set(object.keys).isSubset(of: Set(properties.keys)),
                  (schema["required"] as? [String] ?? []).allSatisfy({ object[$0] != nil }) else { throw invalid() }
            for (key, child) in object { try validate(child, schema: properties[key] as! [String: Any]) }
        case "string":
            guard let string = value as? String, string.count >= (schema["minLength"] as? Int ?? 0),
                  string.count <= (schema["maxLength"] as? Int ?? Int.max), !string.contains("\0") else { throw invalid() }
            if schema["format"] as? String == "uuid", UUID(uuidString: string) == nil { throw invalid() }
        case "integer":
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                  Int(exactly: number.doubleValue) != nil,
                  number.doubleValue >= Double(schema["minimum"] as? Int ?? 0),
                  number.doubleValue <= Double(schema["maximum"] as? Int ?? Int.max) else { throw invalid() }
        case "array":
            guard let array = value as? [Any], array.count >= (schema["minItems"] as? Int ?? 0),
                  array.count <= (schema["maxItems"] as? Int ?? Int.max), let item = schema["items"] as? [String: Any] else { throw invalid() }
            for element in array { try validate(element, schema: item) }
        default: throw invalid()
        }
    }

    private func write(_ message: [String: Any]) {
        do {
            var bytes = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
            bytes.append(10)
            FileHandle.standardOutput.write(bytes)
        } catch {
            FileHandle.standardError.write(Data("MCP response serialization failed\n".utf8))
        }
    }

    private struct RPCError: Error { let code: Int; let message: String }
}
