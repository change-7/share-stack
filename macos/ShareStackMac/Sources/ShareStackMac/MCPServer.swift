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
        Tool(name: "get_status", description: "Read the running Share Stack GUI's receive settings, device addresses and inbox/outbox counts. Launches the GUI if needed; no pairing secrets are returned.", properties: [:]),
        Tool(name: "list_inbox", description: "List actual temporary inbox files, newest first. Returns items and nextOffset; use IDs for receive_files or cancel_inbox_files.", properties: paging),
        Tool(name: "get_item", description: "Read an actual transfer item's metadata, state, saved path and save error by UUID.", properties: ["id": uuid], required: ["id"]),
        Tool(name: "list_history", description: "List transfer history from the GUI, newest first. Returns items and nextOffset.", properties: paging),
        Tool(name: "list_outbox", description: "List files queued for the phone to fetch. Queued does not mean delivered; delivered status is available through get_item or list_history.", properties: paging),
        Tool(name: "list_events", description: "Poll GUI file events. Pass after and streamID from the previous response. Recent 200 events are retained; restart or expired cursors require a fresh snapshot.", properties: ["after": ["type": "integer", "minimum": 0], "streamID": ["type": "string", "maxLength": 64]]),
        Tool(name: "receive_files", description: "Start saving selected inbox files to the folder configured in the GUI. Returns a job ID immediately; poll get_job for saved paths and failures.", properties: ["ids": ids], required: ["ids"], readOnly: false, idempotent: false),
        Tool(name: "receive_all", description: "Start saving all inbox files present when the job starts. Returns a job ID; partial failures stay in the inbox. Use only when the user requests all files.", properties: [:], readOnly: false, idempotent: false),
        Tool(name: "cancel_inbox_files", description: "Delete selected temporary inbox files and their entries. Irreversible; call only for files the user explicitly asks to discard. Returns a job ID.", properties: ["ids": ids], required: ["ids"], readOnly: false, destructive: true, idempotent: false),
        Tool(name: "cancel_outbox_files", description: "Remove selected pending phone transfers and their app-owned copies. Does not delete original source files or files already delivered. Returns a job ID.", properties: ["ids": ids], required: ["ids"], readOnly: false, destructive: true, idempotent: false),
        Tool(name: "send_text", description: "Queue supplied text for the phone. Returns a job ID. The phone must fetch it; job success means queued, not delivered.", properties: ["text": ["type": "string", "minLength": 1, "maxLength": 131072]], required: ["text"], readOnly: false, idempotent: false),
        Tool(name: "send_files", description: "Queue existing local regular files for the phone; originals are preserved. Absolute paths only, no symlinks, max 16 files and 20 GiB each. Returns a job ID; job success means queued, not delivered.", properties: ["paths": ["type": "array", "minItems": 1, "maxItems": 16, "items": ["type": "string", "minLength": 1, "maxLength": 4096]]], required: ["paths"], readOnly: false, idempotent: false, openWorld: true),
        Tool(name: "add_inbox_files", description: "Import user-selected local regular files through the GUI's receive workflow. Originals are preserved. Receive settings decide temporary inbox or automatic save. Absolute paths only, max 16 files and 20 GiB each. Returns a job ID.", properties: ["paths": ["type": "array", "minItems": 1, "maxItems": 16, "items": ["type": "string", "minLength": 1, "maxLength": 4096]]], required: ["paths"], readOnly: false, idempotent: false, openWorld: true),
        Tool(name: "get_job", description: "Read a GUI-owned job's status, completed/total counts, results and failures. Terminal states: succeeded, partial_failure, failed, cancelled, interrupted. Results survive MCP reconnects and GUI restarts.", properties: ["id": uuid], required: ["id"]),
        Tool(name: "list_jobs", description: "List persisted GUI jobs, newest first, with results and errors. Work interrupted by a GUI restart is marked interrupted, not resumed automatically.", properties: paging),
        Tool(name: "cancel_job", description: "Request cancellation of remaining job items. An in-flight file operation may finish first; completed moves and queued transfers are not undone. Terminal jobs are returned unchanged.", properties: ["id": uuid], required: ["id"], readOnly: false)
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
        case "get_item": return try request("GET", "/v1/items/" + (arguments["id"] as! String))
        case "get_job": return try request("GET", "/v1/jobs/" + (arguments["id"] as! String))
        case "cancel_job": return try request("POST", "/v1/jobs/" + (arguments["id"] as! String) + "/cancel")
        case "list_inbox", "list_outbox":
            return page(try request("GET", name == "list_inbox" ? "/v1/inbox" : "/v1/pending") as? [Any] ?? [])
        case "list_history", "list_jobs":
            let items = try request("GET", "\(name == "list_jobs" ? "/v1/jobs" : "/v1/history")?limit=\(limit)&offset=\(offset)")
            var value: [String: Any] = ["items": items]
            if (items as? [Any])?.count == limit { value["nextOffset"] = offset + limit }
            return value
        case "list_events":
            var components = URLComponents()
            components.path = "/v1/events"
            if let after = arguments["after"] as? Int, let stream = arguments["streamID"] as? String {
                components.queryItems = [.init(name: "after", value: String(after)), .init(name: "streamID", value: stream)]
            }
            return try request("GET", components.string!)
        default:
            let operations = ["receive_files": "receive", "receive_all": "receiveAll", "cancel_inbox_files": "cancelInbox",
                              "cancel_outbox_files": "cancelOutbox", "send_text": "sendText", "send_files": "sendFiles", "add_inbox_files": "importFiles"]
            guard let operation = operations[name] else { throw RPCError(code: -32602, message: "Unknown tool") }
            var payload: [String: Any] = ["operation": operation]
            if let ids = arguments["ids"] { payload["itemIDs"] = ids }
            if let paths = arguments["paths"] { payload["filePaths"] = paths }
            if let text = arguments["text"] { payload["text"] = text }
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
