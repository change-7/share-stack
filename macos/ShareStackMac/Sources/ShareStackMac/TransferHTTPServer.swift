import Foundation
import Network

final class TransferHTTPServer {
    static let port: UInt16 = 8765
    private static let maximumHeaderSize = 16 * 1024
    private static let maximumChunkSize = 4 * 1024 * 1024
    fileprivate static let maximumUploadSize = TransferStore.maximumItemSize

    private let store: TransferStore
    private let token: String
    private let tlsIdentity: TLSIdentity
    private let queue = DispatchQueue(label: "com.pdg.sharestack.mac.transfer-server")
    private var listener: NWListener?
    var statusHandler: ((String) -> Void)?
    var itemsChangedHandler: (() -> Void)?

    init(store: TransferStore, token: String, tlsIdentity: TLSIdentity) {
        self.store = store
        self.token = token
        self.tlsIdentity = tlsIdentity
    }

    func start() throws {
        guard let port = NWEndpoint.Port(rawValue: Self.port) else { throw ServerError.invalidPort }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, tlsIdentity.identity)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let listener = try NWListener(using: parameters, on: port)
        listener.service = NWListener.Service(name: "Share Stack", type: NetworkIdentity.bonjourType, domain: nil, txtRecord: nil)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.statusHandler?("갤럭시 연결 준비됨")
            case .failed(let error):
                self?.statusHandler?("수신 서버 오류 · \(error.localizedDescription)")
            case .cancelled:
                self?.statusHandler?("수신 서버 중지됨")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard let endpoint = connection.currentPath?.remoteEndpoint,
                      Self.isAllowedEndpoint(endpoint) else {
                    connection.cancel()
                    return
                }
                self?.receiveHeaders(connection, accumulated: Data())
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveHeaders(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, error == nil, let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            var bytes = accumulated
            bytes.append(data)
            let separator = Data([13, 10, 13, 10])
            guard let boundary = bytes.range(of: separator) else {
                guard bytes.count <= Self.maximumHeaderSize, !isComplete else {
                    self.sendError(connection, status: 400, message: "Invalid request headers")
                    return
                }
                self.receiveHeaders(connection, accumulated: bytes)
                return
            }
            guard boundary.lowerBound <= Self.maximumHeaderSize,
                  let request = HTTPRequest.parse(Data(bytes[..<boundary.lowerBound])) else {
                self.sendError(connection, status: 400, message: "Invalid request")
                return
            }
            let body = Data(bytes[boundary.upperBound...])
            self.route(connection, request: request, initialBody: body)
        }
    }

    private func route(_ connection: NWConnection, request: HTTPRequest, initialBody: Data) {
        guard let authorization = request.headers["authorization"], Self.matchesBearer(authorization, token: token) else {
            sendError(connection, status: 401, message: "Unauthorized")
            return
        }

        let path = request.target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.target
        if routeControl(connection, request: request, path: path, initialBody: initialBody) { return }
        if request.method == "GET", path == "/v1/health" {
            sendJSON(connection, status: 200, value: ["status": "ok"])
            return
        }
        if request.method == "GET", path == "/v1/pending" {
            sendJSON(connection, status: 200, value: store.pendingForGalaxy())
            return
        }
        if request.method == "POST", path == "/v1/items" || path == "/v1/outbox/files" {
            guard request.contentLength >= 0, request.contentLength <= Self.maximumUploadSize else {
                sendError(connection, status: 413, message: "File is too large")
                return
            }
            guard let encodedName = request.headers["x-item-name"],
                  let name = Self.decodeHeader(encodedName),
                  let encodedType = request.headers["x-item-mime"],
                  let mimeType = Self.decodeHeader(encodedType),
                  !mimeType.isEmpty,
                  let expectedSHA256 = request.headers["x-item-sha256"],
                  expectedSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                sendError(connection, status: 400, message: "Missing item metadata")
                return
            }
            do {
                let temporary = try store.makeTemporaryFile()
                let handle = try FileHandle(forWritingTo: temporary)
                receiveBody(
                    connection,
                    request: request,
                    temporary: temporary,
                    handle: handle,
                    name: name,
                    mimeType: mimeType,
                    expectedSHA256: expectedSHA256,
                    outgoing: path == "/v1/outbox/files",
                    initialBody: initialBody,
                    written: 0
                )
            } catch {
                sendError(connection, status: 500, message: "Cannot prepare upload")
            }
            return
        }
        if request.method == "POST", path == "/v1/uploads" {
            guard request.contentLength == 0, initialBody.isEmpty,
                  let id = request.headers["x-upload-id"],
                  let encodedName = request.headers["x-item-name"],
                  let name = Self.decodeHeader(encodedName),
                  let encodedType = request.headers["x-item-mime"],
                  let mimeType = Self.decodeHeader(encodedType),
                  let sizeText = request.headers["x-item-size"], let size = Int64(sizeText),
                  let sha256 = request.headers["x-item-sha256"] else {
                sendError(connection, status: 400, message: "Missing upload metadata")
                return
            }
            do {
                let status = try store.beginUpload(UploadSession(id: id, name: name, mimeType: mimeType, size: size, sha256: sha256))
                sendJSON(connection, status: 200, value: status)
            } catch {
                sendError(connection, status: 400, message: error.localizedDescription)
            }
            return
        }
        if request.method == "PUT", path.hasPrefix("/v1/uploads/") {
            let id = String(path.dropFirst("/v1/uploads/".count))
            guard id.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  request.contentLength > 0, request.contentLength <= Int64(Self.maximumChunkSize),
                  let value = request.headers["content-range"],
                  let range = UploadRange.parse(value),
                  range.length == request.contentLength,
                  Int64(initialBody.count) <= request.contentLength else {
                sendError(connection, status: 400, message: "Invalid upload chunk")
                return
            }
            receiveBodyData(connection, expectedLength: request.contentLength, accumulated: initialBody) { [weak self] data in
                guard let self, let data else {
                    self?.sendError(connection, status: 400, message: "Incomplete upload chunk")
                    return
                }
                do {
                    let status = try self.store.appendUploadChunk(id, range: range, data: data)
                    self.sendJSON(connection, status: 200, value: status)
                } catch {
                    self.sendError(connection, status: 409, message: error.localizedDescription)
                }
            }
            return
        }
        if request.method == "POST", path.hasPrefix("/v1/uploads/"), path.hasSuffix("/finish") {
            guard request.contentLength == 0, initialBody.isEmpty else {
                sendError(connection, status: 400, message: "Unexpected request body")
                return
            }
            let id = String(path.dropFirst("/v1/uploads/".count).dropLast("/finish".count))
            do {
                let item = try store.finishUpload(id)
                received(item)
                sendJSON(connection, status: 201, value: item)
            } catch {
                sendError(connection, status: 409, message: error.localizedDescription)
            }
            return
        }
        if request.method == "POST", path.hasPrefix("/v1/items/"), path.hasSuffix("/ack") {
            guard request.contentLength == 0, initialBody.isEmpty else {
                sendError(connection, status: 400, message: "Unexpected request body")
                return
            }
            let id = String(path.dropFirst("/v1/items/".count).dropLast("/ack".count))
            do {
                guard try store.acknowledge(id) else {
                    sendError(connection, status: 404, message: "Item not found")
                    return
                }
                itemsChangedHandler?()
                sendJSON(connection, status: 200, value: ["status": "delivered"])
            } catch {
                sendError(connection, status: 500, message: "Cannot save delivery state")
            }
            return
        }
        if request.method == "GET", path.hasPrefix("/v1/items/"), path.hasSuffix("/content") {
            let id = String(path.dropFirst("/v1/items/".count).dropLast("/content".count))
            guard let item = store.item(for: id), let file = store.fileURL(for: id) else {
                sendError(connection, status: 404, message: "Item not found")
                return
            }
            if let value = request.headers["range"] {
                guard let range = UploadRange.parse(value, fileSize: item.size) else {
                    sendError(connection, status: 416, message: "Invalid byte range")
                    return
                }
                sendFile(connection, file: file, item: item, range: range)
            } else {
                sendFile(connection, file: file, item: item, range: nil)
            }
            return
        }
        sendError(connection, status: 404, message: "Not found")
    }

    private struct ControlStatus: Encodable {
        let apiVersion = 1
        let inboxCount: Int
        let outboxCount: Int
        let addresses: [String]
        let receiptSettings: ReceiptSettings
    }

    private struct TextSubmission: Decodable {
        let text: String
    }

    private func routeControl(_ connection: NWConnection, request: HTTPRequest, path: String, initialBody: Data) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        let isInbox = path == "/v1/inbox" || path.hasPrefix("/v1/inbox/")
        let isControl = isInbox || ["/v1/status", "/v1/history", "/v1/events", "/v1/outbox/text"].contains(path)
        guard isControl else { return false }
        if path != "/v1/outbox/text", request.contentLength != 0 || !initialBody.isEmpty {
            sendError(connection, status: 400, message: "Unexpected request body")
            return true
        }
        let query = URLComponents(string: request.target)?.queryItems ?? []
        guard Set(query.map(\.name)).count == query.count else {
            sendError(connection, status: 400, message: "Duplicate query parameter")
            return true
        }
        let parameters = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        if request.method == "GET", path == "/v1/status" {
            sendJSON(connection, status: 200, value: ControlStatus(
                inboxCount: store.inboxItems().count, outboxCount: store.pendingForGalaxy().count,
                addresses: NetworkIdentity.localIPv4Addresses() + NetworkIdentity.tailscaleIPv4Addresses(),
                receiptSettings: store.receiptSettings()
            ))
        } else if request.method == "GET", path == "/v1/inbox" {
            sendJSON(connection, status: 200, value: store.inboxItems())
        } else if request.method == "GET", path == "/v1/history" {
            guard let limit = Int(parameters["limit"] ?? "50"), (1...100).contains(limit),
                  let offset = Int(parameters["offset"] ?? "0"), offset >= 0 else {
                sendError(connection, status: 400, message: "Invalid limit or offset")
                return true
            }
            sendJSON(connection, status: 200, value: store.recentItems(limit: limit, offset: offset))
        } else if request.method == "GET", path == "/v1/events" {
            if let value = parameters["after"], Int(value).map({ $0 >= 0 }) != true {
                sendError(connection, status: 400, message: "Invalid event cursor")
                return true
            }
            do {
                sendJSON(connection, status: 200, value: try store.eventPage(
                    after: parameters["after"].flatMap(Int.init), streamID: parameters["streamID"]
                ))
            } catch {
                sendError(connection, status: 409, message: error.localizedDescription)
            }
        } else if request.method == "POST", path == "/v1/inbox/accept-all" {
            let result = store.acceptAllReceivedItems()
            itemsChangedHandler?()
            sendJSON(connection, status: 200, value: result)
        } else if parts.count == 4, parts[0] == "v1", parts[1] == "inbox",
                  parts[3] == "accept", request.method == "POST", UUID(uuidString: parts[2]) != nil {
            let id = parts[2].lowercased()
            guard store.item(for: id) != nil else {
                sendError(connection, status: 404, message: "Item not found")
                return true
            }
            do {
                let item = try store.acceptReceivedItem(id)
                itemsChangedHandler?()
                sendJSON(connection, status: 200, value: item)
            } catch {
                sendError(connection, status: 409, message: error.localizedDescription)
            }
        } else if parts.count == 3, parts[0] == "v1", parts[1] == "inbox",
                  request.method == "DELETE", UUID(uuidString: parts[2]) != nil {
            let id = parts[2].lowercased()
            guard store.item(for: id) != nil else {
                sendError(connection, status: 404, message: "Item not found")
                return true
            }
            do {
                try store.cancelReceivedItem(id)
                itemsChangedHandler?()
                sendJSON(connection, status: 200, value: ["id": id, "status": "cancelled"])
            } catch {
                sendError(connection, status: 409, message: error.localizedDescription)
            }
        } else if request.method == "POST", path == "/v1/outbox/text" {
            guard request.contentLength > 0, request.contentLength <= 1024 * 1024,
                  request.headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else {
                sendError(connection, status: 400, message: "Expected application/json body up to 1 MiB")
                return true
            }
            receiveBodyData(connection, expectedLength: request.contentLength, accumulated: initialBody) { [weak self] data in
                guard let self else { return }
                guard let data, let submission = try? JSONDecoder().decode(TextSubmission.self, from: data),
                      !submission.text.isEmpty else {
                    self.sendError(connection, status: 400, message: "Expected nonempty text")
                    return
                }
                do {
                    let item = try self.store.enqueueText(submission.text)
                    self.itemsChangedHandler?()
                    self.sendJSON(connection, status: 201, value: item)
                } catch {
                    self.sendError(connection, status: 409, message: error.localizedDescription)
                }
            }
        } else {
            sendError(connection, status: 404, message: "Unknown API operation")
        }
        return true
    }

    private func received(_ item: TransferItem) {
        itemsChangedHandler?()
        if item.state == "saved" {
            statusHandler?("지정 폴더에 저장됨 · \(item.name)")
        } else if item.saveError != nil {
            statusHandler?("자동 저장 실패 · 보관함에서 다시 수신하세요")
        } else {
            statusHandler?("보관함 수신 대기 · \(item.name)")
        }
    }

    private func receiveBodyData(
        _ connection: NWConnection,
        expectedLength: Int64,
        accumulated: Data,
        completion: @escaping (Data?) -> Void
    ) {
        guard Int64(accumulated.count) <= expectedLength else {
            completion(nil)
            return
        }
        if Int64(accumulated.count) == expectedLength {
            completion(accumulated)
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumChunkSize) { [weak self] data, _, isComplete, error in
            guard let self, error == nil, let data, !data.isEmpty else {
                completion(nil)
                return
            }
            var next = accumulated
            next.append(data)
            if isComplete && Int64(next.count) < expectedLength {
                completion(nil)
                return
            }
            self.receiveBodyData(connection, expectedLength: expectedLength, accumulated: next, completion: completion)
        }
    }

    private func receiveBody(
        _ connection: NWConnection,
        request: HTTPRequest,
        temporary: URL,
        handle: FileHandle,
        name: String,
        mimeType: String,
        expectedSHA256: String,
        outgoing: Bool,
        initialBody: Data,
        written: Int64
    ) {
        guard Int64(initialBody.count) <= request.contentLength else {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
            sendError(connection, status: 400, message: "Request body exceeds Content-Length")
            return
        }
        do {
            if !initialBody.isEmpty { try handle.write(contentsOf: initialBody) }
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
            sendError(connection, status: 500, message: "Cannot write upload")
            return
        }
        let totalWritten = written + Int64(initialBody.count)
        guard totalWritten <= request.contentLength else {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
            sendError(connection, status: 400, message: "Request body exceeds Content-Length")
            return
        }
        if totalWritten == request.contentLength {
            do {
                try handle.close()
                let item: TransferItem
                if outgoing {
                    item = try store.enqueueTemporaryFile(temporary, name: name, mimeType: mimeType, expectedSHA256: expectedSHA256)
                    itemsChangedHandler?()
                } else {
                    item = try store.saveReceivedFile(temporary, name: name, mimeType: mimeType, expectedSHA256: expectedSHA256)
                    received(item)
                }
                sendJSON(connection, status: 201, value: item)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                sendError(connection, status: 400, message: error.localizedDescription)
            }
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, error == nil, let data, !data.isEmpty, !isComplete else {
                try? handle.close()
                try? FileManager.default.removeItem(at: temporary)
                connection.cancel()
                return
            }
            self.receiveBody(
                connection,
                request: request,
                temporary: temporary,
                handle: handle,
                name: name,
                mimeType: mimeType,
                expectedSHA256: expectedSHA256,
                outgoing: outgoing,
                initialBody: data,
                written: totalWritten
            )
        }
    }

    private func sendFile(_ connection: NWConnection, file: URL, item: TransferItem, range: UploadRange?) {
        do {
            let handle = try FileHandle(forReadingFrom: file)
            let offset = range?.start ?? 0
            let length = range?.length ?? item.size
            try handle.seek(toOffset: UInt64(offset))
            let status = range == nil ? "200 OK" : "206 Partial Content"
            let rangeHeader = range.map { "Content-Range: bytes \($0.start)-\($0.end)/\($0.total)\r\n" } ?? ""
            let header = Data((
                "HTTP/1.1 \(status)\r\n" +
                "Content-Type: \(Self.safeHeader(item.mimeType))\r\n" +
                "Content-Length: \(length)\r\n" +
                rangeHeader +
                "Connection: close\r\n\r\n"
            ).utf8)
            connection.send(content: header, completion: .contentProcessed { [weak self] error in
                guard let self, error == nil else {
                    try? handle.close()
                    connection.cancel()
                    return
                }
                self.sendNextFileChunk(connection, handle: handle, remaining: length)
            })
        } catch {
            sendError(connection, status: 500, message: "Cannot read item")
        }
    }

    private func sendNextFileChunk(_ connection: NWConnection, handle: FileHandle, remaining: Int64) {
        guard remaining > 0 else {
            try? handle.close()
            connection.cancel()
            return
        }
        do {
            guard let chunk = try handle.read(upToCount: min(64 * 1024, Int(remaining))), !chunk.isEmpty else {
                try handle.close()
                connection.cancel()
                return
            }
            connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                guard let self, error == nil else {
                    try? handle.close()
                    connection.cancel()
                    return
                }
                self.sendNextFileChunk(connection, handle: handle, remaining: remaining - Int64(chunk.count))
            })
        } catch {
            try? handle.close()
            connection.cancel()
        }
    }

    private func sendJSON<T: Encodable>(_ connection: NWConnection, status: Int, value: T) {
        do {
            let body = try JSONEncoder().encode(value)
            let reason = status == 201 ? "Created" : "OK"
            let header = Data((
                "HTTP/1.1 \(status) \(reason)\r\n" +
                "Content-Type: application/json; charset=utf-8\r\n" +
                "Content-Length: \(body.count)\r\n" +
                "Connection: close\r\n\r\n"
            ).utf8)
            connection.send(content: header + body, completion: .contentProcessed { _ in connection.cancel() })
        } catch {
            sendError(connection, status: 500, message: "Cannot encode response")
        }
    }

    private func sendError(_ connection: NWConnection, status: Int, message: String) {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
        let reason: String
        switch status {
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 413: reason = "Payload Too Large"
        case 416: reason = "Range Not Satisfiable"
        case 409: reason = "Conflict"
        default: reason = "Internal Server Error"
        }
        let header = Data((
            "HTTP/1.1 \(status) \(reason)\r\n" +
            "Content-Type: application/json; charset=utf-8\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Connection: close\r\n\r\n"
        ).utf8)
        connection.send(content: header + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func matchesBearer(_ header: String, token: String) -> Bool {
        let expected = Array("Bearer \(token)".utf8)
        let received = Array(header.utf8)
        guard expected.count == received.count else { return false }
        return zip(expected, received).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func isAllowedEndpoint(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        let value = String(describing: host)
        return value == "127.0.0.1" || value == "::1" || NetworkIdentity.isTailscaleIPv4(value) || NetworkIdentity.isPrivateIPv4(value)
    }

    private static func decodeHeader(_ value: String) -> String? {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func safeHeader(_ value: String) -> String {
        value.filter { $0.isASCII && !$0.isNewline && $0 != "\r" }
    }

    enum ServerError: Error {
        case invalidPort
    }
}

private struct HTTPRequest {
    let method: String
    let target: String
    let headers: [String: String]
    let contentLength: Int64

    static func parse(_ data: Data) -> HTTPRequest? {
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let requestLine = first.split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3,
              requestLine[2] == "HTTP/1.1",
              requestLine[1].first == "/" else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, headers[name] == nil else { return nil }
            headers[name] = value
        }
        guard headers["transfer-encoding"] == nil else { return nil }
        let contentLength: Int64
        if let value = headers["content-length"] {
            guard let parsed = Int64(value), parsed >= 0,
                  parsed <= TransferHTTPServer.maximumUploadSize else { return nil }
            contentLength = parsed
        } else {
            contentLength = 0
        }
        return HTTPRequest(
            method: String(requestLine[0]),
            target: String(requestLine[1]),
            headers: headers,
            contentLength: contentLength
        )
    }
}
