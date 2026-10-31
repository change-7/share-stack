import Foundation
import Network
import UniformTypeIdentifiers

final class TransferHTTPServer {
    static let port: UInt16 = 8765
    private static let maximumHeaderSize = 16 * 1024
    private static let maximumChunkSize = 8 * 1024 * 1024
    fileprivate static let maximumUploadSize = TransferStore.maximumItemSize
    private static let transferBufferSize = 256 * 1024
    private static let maximumConnections = 32
    /// 클라이언트가 끊긴 채 남은 연결이 슬롯을 계속 차지하지 않도록 하는 무응답 한도.
    private static let idleTimeout: TimeInterval = 120
    private static let idleSweepInterval: TimeInterval = 15

    private let listeningPort: UInt16
    private let store: TransferStore
    private let token: String
    private let aiToken: String
    private let tlsIdentity: TLSIdentity
    private let jobs: TransferJobs
    private let queue = DispatchQueue(label: "com.pdg.sharestack.mac.transfer-server", autoreleaseFrequency: .workItem)
    private let workQueue = DispatchQueue(label: "com.pdg.sharestack.mac.transfer-work", qos: .userInitiated,
                                          attributes: .concurrent, autoreleaseFrequency: .workItem)
    private let uploadQueue = DispatchQueue(label: "com.pdg.sharestack.mac.transfer-upload", qos: .userInitiated,
                                             autoreleaseFrequency: .workItem)
    private var listener: NWListener?
    private var portRetryDelay: TimeInterval = 0.25
    private var connections: [ObjectIdentifier: ConnectionEntry] = [:]
    private var idleTimer: DispatchSourceTimer?
    private let aiJobLock = NSLock()
    private var aiJobIDs = Set<String>()
    var statusHandler: ((String) -> Void)?
    var itemsChangedHandler: (() -> Void)? {
        didSet { jobs.setChangeHandler(itemsChangedHandler) }
    }

    private struct ConnectionEntry {
        let connection: NWConnection
        var lastActivity: Date
        var isProcessing = false
    }

    init(store: TransferStore, token: String, aiToken: String, tlsIdentity: TLSIdentity, listeningPort: UInt16 = TransferHTTPServer.port) throws {
        self.listeningPort = listeningPort
        self.store = store
        self.token = token
        self.aiToken = aiToken
        self.tlsIdentity = tlsIdentity
        self.jobs = TransferJobs(store: store)
    }

    func start() throws {
        guard let port = NWEndpoint.Port(rawValue: listeningPort) else { throw ServerError.invalidPort }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, tlsIdentity.identity)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let listener = try NWListener(using: parameters, on: port)
        if listeningPort == Self.port { listener.service = NWListener.Service(name: "Share Stack", type: NetworkIdentity.bonjourType, domain: nil, txtRecord: nil) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            switch state {
            case .ready:
                self.portRetryDelay = 0.25
                self.statusHandler?("갤럭시 연결 준비됨")
            case .failed(let error):
                self.statusHandler?("수신 서버 오류 · \(error.localizedDescription)")
                if case .posix(.EADDRINUSE) = error {
                    // A duplicate/relaunch can briefly own the port; a failed NWListener never retries itself.
                    listener.stateUpdateHandler = nil
                    listener.cancel()
                    let delay = self.portRetryDelay
                    self.portRetryDelay = min(delay * 2, 4)
                    self.queue.asyncAfter(deadline: .now() + delay) { [weak self, weak listener] in
                        guard let self, let listener, self.listener === listener else { return }
                        do { try self.start() }
                        catch { self.statusHandler?("수신 서버 오류 · \(error.localizedDescription)") }
                    }
                }
            case .cancelled:
                self.statusHandler?("수신 서버 중지됨")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        startIdleSweeper()
        listener.start(queue: queue)
    }

    private func startIdleSweeper() {
        guard idleTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.idleSweepInterval, repeating: Self.idleSweepInterval)
        timer.setEventHandler { [weak self] in self?.closeIdleConnections() }
        timer.resume()
        idleTimer = timer
    }

    private func closeIdleConnections() {
        let deadline = Date().addingTimeInterval(-Self.idleTimeout)
        let expired = connections
            .filter { !$0.value.isProcessing && $0.value.lastActivity < deadline }
            .map(\.key)
        for identifier in expired {
            guard let entry = connections.removeValue(forKey: identifier) else { continue }
            entry.connection.cancel()
        }
    }

    /// 네트워크에서 데이터를 주고받을 때마다 호출한다. (queue에서만 호출)
    private func touch(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)]?.lastActivity = Date()
    }

    /// 해시·검증처럼 응답 없이 오래 걸리는 작업 중에는 무응답 정리를 건너뛴다.
    private func beginProcessing(_ connection: NWConnection) {
        queue.async { [weak self] in
            guard let self, var entry = self.connections[ObjectIdentifier(connection)] else { return }
            entry.isProcessing = true
            entry.lastActivity = Date()
            self.connections[ObjectIdentifier(connection)] = entry
        }
    }

    private func endProcessing(_ connection: NWConnection) {
        queue.async { [weak self] in
            guard let self, var entry = self.connections[ObjectIdentifier(connection)] else { return }
            entry.isProcessing = false
            entry.lastActivity = Date()
            self.connections[ObjectIdentifier(connection)] = entry
        }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < Self.maximumConnections else { connection.cancel(); return }
        let identifier = ObjectIdentifier(connection)
        connections[identifier] = ConnectionEntry(connection: connection, lastActivity: Date())
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .ready:
                guard let endpoint = connection.currentPath?.remoteEndpoint,
                      Self.isAllowedEndpoint(endpoint) else {
                    connection.cancel()
                    return
                }
                self?.receiveHeaders(connection, accumulated: Data())
            case .failed, .cancelled:
                self?.connections.removeValue(forKey: identifier)
                connection.stateUpdateHandler = nil
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
            self.touch(connection)
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
        guard let caller = Self.caller(for: request.headers["authorization"], phoneToken: token, aiToken: aiToken) else {
            sendError(connection, status: 401, message: "Unauthorized")
            return
        }
        if caller == .aiMCP && !Self.isLoopback(connection.currentPath?.remoteEndpoint) {
            sendError(connection, status: 403, message: "PERMISSION_DENIED")
            return
        }
        let path = request.target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.target
        guard Self.mayAccess(path, caller: caller) else {
            sendError(connection, status: 403, message: "PERMISSION_DENIED")
            return
        }
        if routeWorkspaces(connection, request: request, path: path, initialBody: initialBody, caller: caller) { return }
        if routePhoneAIRead(connection, request: request, path: path, initialBody: initialBody, caller: caller) { return }
        if routeExchangeText(connection, request: request, path: path, initialBody: initialBody, caller: caller) { return }
        if routeSharedFiles(connection, request: request, path: path, caller: caller) { return }
        if routeJobs(connection, request: request, path: path, initialBody: initialBody, caller: caller) { return }
        if routeControl(connection, request: request, path: path, initialBody: initialBody) { return }
        let itemParts = path.split(separator: "/")
        if request.method == "GET", itemParts.count == 3, itemParts[0] == "v1", itemParts[1] == "items",
           UUID(uuidString: String(itemParts[2])) != nil {
            if let item = store.item(for: String(itemParts[2]).lowercased()) {
                sendJSON(connection, status: 200, value: item)
            } else {
                sendError(connection, status: 404, message: "Item not found")
            }
            return
        }
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
            var temporary: URL?
            do {
                let file = try store.makeTemporaryFile()
                temporary = file
                let handle = try FileHandle(forWritingTo: file)
                receiveBody(
                    connection,
                    request: request,
                    temporary: file,
                    handle: handle,
                    name: name,
                    mimeType: mimeType,
                    expectedSHA256: expectedSHA256,
                    outgoing: path == "/v1/outbox/files",
                    initialBody: initialBody,
                    written: 0
                )
                temporary = nil
            } catch {
                if let temporary { try? FileManager.default.removeItem(at: temporary) }
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
            do {
                let writer = try store.beginUploadChunk(id, range: range)
                receiveUploadChunk(connection, writer: writer, expectedLength: request.contentLength,
                                   initialBody: initialBody, received: 0)
            } catch {
                sendError(connection, status: 409, message: error.localizedDescription)
            }
            return
        }
        if request.method == "POST", path.hasPrefix("/v1/uploads/"), path.hasSuffix("/finish") {
            guard request.contentLength == 0, initialBody.isEmpty else {
                sendError(connection, status: 400, message: "Unexpected request body")
                return
            }
            let id = String(path.dropFirst("/v1/uploads/".count).dropLast("/finish".count))
            workQueue.async { [weak self] in
                guard let self else { return }
                self.beginProcessing(connection)
                do {
                    let item = try self.store.finishUpload(id)
                    self.received(item)
                    self.sendJSON(connection, status: 201, value: item)
                } catch {
                    self.sendError(connection, status: 409, message: error.localizedDescription)
                }
                self.endProcessing(connection)
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

    private func routeWorkspaces(_ connection: NWConnection, request: HTTPRequest, path: String,
                                 initialBody: Data, caller: Caller) -> Bool {
        guard path == "/v1/workspace-session" || path == "/v1/workspaces" || path.hasPrefix("/v1/workspaces/") else { return false }
        guard caller == .aiMCP else { sendError(connection, status: 403, message: "PERMISSION_DENIED"); return true }
        func respond(_ body: [String: Any]) {
            workQueue.async {
                do {
                    let workspace = try self.store.workspaceStore()
                    if path == "/v1/workspace-session" {
                        guard request.method == "POST", Set(body.keys) == ["label"], let label = body["label"] as? String, label.utf8.count <= 256 else { throw WorkspaceStore.Failure.invalid }
                        self.sendJSON(connection, status: 200, value: try workspace.registerSession(label: label))
                        return
                    }
                    guard let credential = request.headers["x-workspace-session"], credential.count <= 128 else { throw WorkspaceStore.Failure.denied }
                    let parts = path.split(separator: "/").map(String.init)
                    let query = URLComponents(string: request.target)?.queryItems ?? []
                    guard Set(query.map(\.name)).count == query.count else { throw WorkspaceStore.Failure.invalid }
                    func number(_ key: String, _ fallback: Int) throws -> Int { guard let item = query.first(where: { $0.name == key }) else { return fallback }; guard let value = item.value, let n = Int(value), n >= 0 else { throw WorkspaceStore.Failure.invalid }; return n }
                    if request.method == "GET" {
                        guard request.contentLength == 0 else { throw WorkspaceStore.Failure.invalid }
                        if parts.count == 2 {
                            guard query.isEmpty else { throw WorkspaceStore.Failure.invalid }
                            let records = try workspace.visibleWorkspaces(credential: credential)
                            self.sendJSON(connection, status: 200, value: ["items": records.map { ["id": $0.id, "name": $0.name, "mode": $0.mode.rawValue] }]); return
                        }
                        guard parts.count >= 4, UUID(uuidString: parts[2]) != nil else { throw WorkspaceStore.Failure.denied }
                        let id = parts[2].lowercased()
                        if parts.count == 4 && parts[3] == "entries" {
                            guard Set(query.map(\.name)).isSubset(of: ["relativePath", "cursor", "limit"]) else { throw WorkspaceStore.Failure.invalid }
                            let value = try workspace.entries(id, path: query.first(where: { $0.name == "relativePath" })?.value ?? "", cursor: number("cursor", 0), limit: number("limit", 50), credential: credential)
                            self.sendJSON(connection, status: 200, value: value); return
                        }
                        if parts.count == 4 && parts[3] == "changes" {
                            guard Set(query.map(\.name)).isSubset(of: ["cursor", "limit"]) else { throw WorkspaceStore.Failure.invalid }
                            self.sendJSON(connection, status: 200, value: try workspace.changes(id, cursor: query.first(where: { $0.name == "cursor" })?.value ?? "0:0", limit: number("limit", 20), credential: credential)); return
                        }
                        if parts.count >= 5 && parts[3] == "files", UUID(uuidString: parts[4]) != nil {
                            if parts.count == 5 {
                                guard query.isEmpty else { throw WorkspaceStore.Failure.invalid }
                                self.sendJSON(connection, status: 200, value: try workspace.info(id, fileID: parts[4].lowercased(), credential: credential)); return
                            }
                            if parts.count == 6 && parts[5] == "content" {
                                guard Set(query.map(\.name)).isSubset(of: ["offset", "limit"]) else { throw WorkspaceStore.Failure.invalid }
                                self.sendJSON(connection, status: 200, value: try workspace.read(id, fileID: parts[4].lowercased(), offset: number("offset", 0), limit: number("limit", 4096), credential: credential)); return
                            }
                        }
                        throw WorkspaceStore.Failure.denied
                    }
                    guard request.method == "POST", query.isEmpty, parts.count == 4, UUID(uuidString: parts[2]) != nil else { throw WorkspaceStore.Failure.denied }
                    let id = parts[2].lowercased()
                    func string(_ key: String) throws -> String { guard let value = body[key] as? String else { throw WorkspaceStore.Failure.invalid }; return value }
                    if parts[3] == "create" {
                        guard Set(body.keys) == ["relativePath", "content", "requestKey"] else { throw WorkspaceStore.Failure.invalid }
                        self.sendJSON(connection, status: 200, value: try workspace.create(id, path: string("relativePath"), content: string("content"), requestKey: string("requestKey"), credential: credential)); return
                    }
                    if parts[3] == "patch" {
                        guard Set(body.keys) == ["fileId", "expectedHash", "patch", "requestKey"] else { throw WorkspaceStore.Failure.invalid }
                        self.sendJSON(connection, status: 200, value: try workspace.patch(id, fileID: string("fileId"), expectedHash: string("expectedHash"), patch: string("patch"), requestKey: string("requestKey"), credential: credential)); return
                    }
                    throw WorkspaceStore.Failure.denied
                } catch let error as WorkspaceStore.Failure {
                    let message: String, status: Int
                    switch error {
                    case .denied: message = "PERMISSION_DENIED"; status = 403
                    case .conflict: message = "CONFLICT"; status = 409
                    case .limit: message = "LIMIT_EXCEEDED"; status = 413
                    case .invalid: message = "INVALID_REQUEST"; status = 400
                    case .io: message = "WORKSPACE_UNAVAILABLE"; status = 409
                    }
                    self.sendError(connection, status: status, message: message)
                } catch { self.sendError(connection, status: 409, message: "WORKSPACE_UNAVAILABLE") }
            }
        }
        if request.method == "GET" { respond([:]); return true }
        guard request.method == "POST", request.contentLength > 0, request.contentLength <= 1024 * 1024,
              request.headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else {
            sendError(connection, status: 403, message: "PERMISSION_DENIED"); return true
        }
        receiveBodyData(connection, expectedLength: request.contentLength, accumulated: initialBody) { data in
            guard let data, let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { self.sendError(connection, status: 400, message: "INVALID_REQUEST"); return }
            respond(body)
        }
        return true
    }

    private func routeSharedFiles(_ connection: NWConnection, request: HTTPRequest, path: String, caller: Caller) -> Bool {
        guard path == "/v1/shared-files" || path.hasPrefix("/v1/shared-files/") else { return false }
        guard caller == .aiMCP else {
            sendError(connection, status: 403, message: "PERMISSION_DENIED")
            return true
        }
        guard request.method == "GET", request.contentLength == 0 else {
            sendError(connection, status: 400, message: "Shared file endpoints accept GET without a body")
            return true
        }
        let query = URLComponents(string: request.target)?.queryItems ?? []
        func number(_ name: String, default value: Int) -> Int? {
            guard let raw = query.first(where: { $0.name == name })?.value else { return value }
            return Int(raw)
        }
        if path == "/v1/shared-files" {
            guard let offset = number("offset", default: 0), (0...1_000_000).contains(offset),
                  let limit = number("limit", default: 50), (1...100).contains(limit) else {
                sendError(connection, status: 400, message: "Invalid shared file page")
                return true
            }
            do { sendJSON(connection, status: 200, value: try store.aiSharedFiles(offset: offset, limit: limit)) }
            catch { sendError(connection, status: 403, message: "AI Exchange reading is unavailable") }
            return true
        }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 3 || parts.count == 4, UUID(uuidString: parts[2]) != nil else {
            sendError(connection, status: 404, message: "Shared file not found")
            return true
        }
        let id = parts[2].lowercased()
        do {
            if parts.count == 3 {
                sendJSON(connection, status: 200, value: try store.aiSharedFileInfo(id))
            } else if parts[3] == "content" {
                guard let offset = number("offset", default: 0), let limit = number("limit", default: 4096) else {
                    sendError(connection, status: 400, message: "Invalid shared file range")
                    return true
                }
                sendJSON(connection, status: 200, value: try store.readAIExchangeFile(id, offset: Int64(offset), limit: limit))
            } else {
                sendError(connection, status: 404, message: "Shared file not found")
            }
        } catch let error as TransferStore.StoreError {
            let status: Int
            switch error {
            case .sharedFileNotFound: status = 404
            case .unsupportedSharedFile: status = 415
            case .invalidSharedFileRange: status = 416
            case .invalidSharedFileEncoding: status = 422
            case .sharedFileUnavailable, .checksumMismatch, .exchangeUnavailable: status = 409
            case .aiExchangeDisabled: status = 403
            default: status = 500
            }
            sendError(connection, status: status, message: "AI Exchange file is unavailable")
        } catch {
            sendError(connection, status: 500, message: "Cannot read shared file")
        }
        return true
    }

    private func routeJobs(_ connection: NWConnection, request: HTTPRequest, path: String, initialBody: Data,
                           caller: Caller) -> Bool {
        guard path == "/v1/jobs" || path.hasPrefix("/v1/jobs/") else { return false }
        guard let endpoint = connection.currentPath?.remoteEndpoint,
              case .hostPort(let host, _) = endpoint,
              ["127.0.0.1", "::1"].contains(String(describing: host)) else {
            sendError(connection, status: 403, message: "Job control is available only on this Mac")
            return true
        }
        if request.method == "POST", path == "/v1/jobs" {
            guard request.contentLength > 0, request.contentLength <= 1024 * 1024,
                  request.headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else {
                sendError(connection, status: 400, message: "Expected job JSON up to 1 MiB")
                return true
            }
            receiveBodyData(connection, expectedLength: request.contentLength, accumulated: initialBody) { [weak self] data in
                guard let self else { return }
                do {
                    guard let data else { throw JobError.invalidInput }
                    let request = try JSONDecoder().decode(TransferJobRequest.self, from: data)
                    if !Self.maySubmitHTTPJob(request.operation, caller: caller) {
                        self.sendError(connection, status: 403, message: "PERMISSION_DENIED")
                        return
                    }
                    let job = try self.jobs.submit(request)
                    if caller == .aiMCP {
                        self.aiJobLock.lock()
                        self.aiJobIDs.insert(job.id)
                        self.aiJobLock.unlock()
                    }
                    self.sendJSON(connection, status: 201, value: job)
                } catch {
                    self.sendError(connection, status: 400, message: error.localizedDescription)
                }
            }
            return true
        }
        guard request.contentLength == 0, initialBody.isEmpty else {
            sendError(connection, status: 400, message: "Unexpected request body")
            return true
        }
        let parts = path.split(separator: "/")
        do {
            if parts.count == 3, request.method == "GET", UUID(uuidString: String(parts[2])) != nil {
                let id = String(parts[2]).lowercased()
                guard caller != .aiMCP || isAIJob(id) else { throw JobError.notFound }
                sendJSON(connection, status: 200, value: try jobs.get(id))
            } else if parts.count == 4, request.method == "POST", parts[3] == "cancel", UUID(uuidString: String(parts[2])) != nil {
                let id = String(parts[2]).lowercased()
                guard caller != .aiMCP || isAIJob(id) else { throw JobError.notFound }
                sendJSON(connection, status: 200, value: try jobs.cancel(id))
            } else {
                sendError(connection, status: 404, message: "Unknown job operation")
            }
        } catch JobError.invalidInput {
            sendError(connection, status: 400, message: "Invalid job input")
        } catch JobError.notFound {
            sendError(connection, status: 404, message: "Job not found")
        } catch {
            sendError(connection, status: 500, message: error.localizedDescription)
        }
        return true
    }

    private func isAIJob(_ id: String) -> Bool {
        aiJobLock.lock()
        defer { aiJobLock.unlock() }
        return aiJobIDs.contains(id)
    }

    enum Caller: Equatable {
        case phone
        case aiMCP
    }

    static func caller(for authorization: String?, phoneToken: String, aiToken: String) -> Caller? {
        guard let authorization else { return nil }
        if matchesBearer(authorization, token: aiToken) { return .aiMCP }
        if matchesBearer(authorization, token: phoneToken) { return .phone }
        return nil
    }

    static func mayAccess(_ path: String, caller: Caller) -> Bool {
        let sharedFiles = path == "/v1/shared-files" || path.hasPrefix("/v1/shared-files/")
        let workspaces = path == "/v1/workspace-session" || path == "/v1/workspaces" || path.hasPrefix("/v1/workspaces/")
        let jobs = path == "/v1/jobs" || path.hasPrefix("/v1/jobs/")
        let exchangeText = path == "/v1/ai-exchange/text"
        switch caller {
        case .phone: return !sharedFiles && !exchangeText && !workspaces
        case .aiMCP: return path == "/v1/health" || sharedFiles || jobs || exchangeText || workspaces
        }
    }

    static func maySubmitHTTPJob(_ operation: TransferJobRequest.Operation, caller: Caller) -> Bool {
        guard operation != .sendFiles && operation != .importFiles else { return false }
        return caller != .aiMCP || maySubmitAIJob(operation)
    }

    static func maySubmitAIJob(_ operation: TransferJobRequest.Operation) -> Bool {
        operation == .receiveTextFile
    }

    private static func isLoopback(_ endpoint: NWEndpoint?) -> Bool {
        guard let endpoint, case .hostPort(let host, _) = endpoint else { return false }
        return ["127.0.0.1", "::1"].contains(String(describing: host))
    }

    private struct ExchangeTextSubmission: Decodable {
        let filename: String
        let content: String
    }

    private func routeExchangeText(_ connection: NWConnection, request: HTTPRequest, path: String,
                                   initialBody: Data, caller: Caller) -> Bool {
        guard path == "/v1/ai-exchange/text" else { return false }
        guard caller == .aiMCP else {
            sendError(connection, status: 403, message: "PERMISSION_DENIED")
            return true
        }
        guard request.method == "POST", request.contentLength > 0, request.contentLength <= 1024 * 1024,
              request.headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else {
            sendError(connection, status: 400, message: "Invalid AI Exchange text request")
            return true
        }
        receiveBodyData(connection, expectedLength: request.contentLength, accumulated: initialBody) { [weak self] data in
            guard let self else { return }
            do {
                guard let data,
                      let submission = try? JSONDecoder().decode(ExchangeTextSubmission.self, from: data) else {
                    self.sendError(connection, status: 400, message: "Invalid AI Exchange text request")
                    return
                }
                let ext = URL(fileURLWithPath: submission.filename).pathExtension
                let mimeType = UTType(filenameExtension: ext)?.preferredMIMEType ?? "text/plain"
                let file = try self.store.receiveExchangeTextFile(filename: submission.filename,
                                                                  content: submission.content, mimeType: mimeType)
                self.itemsChangedHandler?()
                self.sendJSON(connection, status: 201, value: file)
            } catch {
                self.sendError(connection, status: 400, message: "AI Exchange text registration failed")
            }
        }
        return true
    }

    private func routePhoneAIRead(_ connection: NWConnection, request: HTTPRequest, path: String,
                                  initialBody: Data, caller: Caller) -> Bool {
        guard path == "/v1/phone-ai-read" else { return false }
        guard caller == .phone else {
            sendError(connection, status: 403, message: "PERMISSION_DENIED")
            return true
        }
        guard request.method == "POST", request.contentLength > 0, request.contentLength <= 4096,
              request.headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else {
            sendError(connection, status: 400, message: "Invalid phone consent request")
            return true
        }
        receiveBodyData(connection, expectedLength: request.contentLength, accumulated: initialBody) { [weak self] data in
            guard let self else { return }
            guard let data, let intent = try? JSONDecoder().decode(PhoneAIReadRequest.self, from: data) else {
                self.sendError(connection, status: 400, message: "Invalid phone consent request")
                return
            }
            self.beginProcessing(connection)
            self.workQueue.async {
                defer { self.endProcessing(connection); self.itemsChangedHandler?() }
                do { self.sendJSON(connection, status: 200, value: try self.store.applyPhoneAIRead(intent)) }
                catch { self.sendError(connection, status: 409, message: error.localizedDescription) }
            }
        }
        return true
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
        let isControl = isInbox || ["/v1/status", "/v1/events", "/v1/outbox/text"].contains(path)
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
        guard Int64(accumulated.count) <= expectedLength, expectedLength <= Int64(Int.max) else {
            completion(nil)
            return
        }
        let buffer = BodyBuffer(accumulated, capacity: Int(expectedLength))
        collectBodyData(connection, expectedLength: expectedLength, buffer: buffer, completion: completion)
    }

    private func receiveUploadChunk(
        _ connection: NWConnection,
        writer: UploadChunkWriter,
        expectedLength: Int64,
        initialBody: Data,
        received: Int64
    ) {
        guard Int64(initialBody.count) <= expectedLength - received else {
            writer.cancel()
            sendError(connection, status: 400, message: "Request body exceeds Content-Length")
            return
        }
        if received + Int64(initialBody.count) == expectedLength {
            uploadQueue.async { [weak self] in
                guard let self else { writer.cancel(); return }
                do {
                    if !initialBody.isEmpty { try writer.append(initialBody) }
                    self.sendJSON(connection, status: 200, value: try writer.finish())
                } catch {
                    writer.cancel()
                    self.sendError(connection, status: 500, message: "Cannot write upload")
                }
            }
            return
        }
        if !initialBody.isEmpty {
            let next = received + Int64(initialBody.count)
            uploadQueue.async { [weak self] in
                guard let self else { writer.cancel(); return }
                do {
                    try writer.append(initialBody)
                    self.queue.async { [weak self] in
                        guard let self else { writer.cancel(); return }
                        self.receiveUploadChunk(connection, writer: writer, expectedLength: expectedLength,
                                                initialBody: Data(), received: next)
                    }
                } catch {
                    writer.cancel()
                    self.sendError(connection, status: 500, message: "Cannot write upload")
                }
            }
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.transferBufferSize) { [weak self] data, _, isComplete, error in
            guard let self, error == nil, let data, !data.isEmpty else {
                writer.cancel()
                connection.cancel()
                return
            }
            self.touch(connection)
            let next = received + Int64(data.count)
            guard next <= expectedLength else {
                writer.cancel()
                self.sendError(connection, status: 400, message: "Request body exceeds Content-Length")
                return
            }
            self.uploadQueue.async {
                do {
                    try writer.append(data)
                    if isComplete && next < expectedLength {
                        writer.cancel()
                        connection.cancel()
                    } else {
                        self.queue.async { [self] in
                            self.receiveUploadChunk(connection, writer: writer, expectedLength: expectedLength,
                                                    initialBody: Data(), received: next)
                        }
                    }
                } catch {
                    writer.cancel()
                    self.sendError(connection, status: 500, message: "Cannot write upload")
                }
            }
        }
    }

    private final class BodyBuffer {
        var data: Data

        init(_ initial: Data, capacity: Int) {
            data = initial
            data.reserveCapacity(capacity)
        }

        func append(_ chunk: Data) {
            data.append(chunk)
        }
    }

    private func collectBodyData(
        _ connection: NWConnection,
        expectedLength: Int64,
        buffer: BodyBuffer,
        completion: @escaping (Data?) -> Void
    ) {
        if Int64(buffer.data.count) == expectedLength {
            completion(buffer.data)
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.transferBufferSize) { [weak self] data, _, isComplete, error in
            guard let self, error == nil, let data, !data.isEmpty else {
                completion(nil)
                return
            }
            self.touch(connection)
            buffer.append(data)
            guard Int64(buffer.data.count) <= expectedLength else {
                completion(nil)
                return
            }
            if isComplete && Int64(buffer.data.count) < expectedLength {
                completion(nil)
                return
            }
            self.collectBodyData(connection, expectedLength: expectedLength, buffer: buffer, completion: completion)
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
            try? handle.close()
            workQueue.async { [weak self] in
                guard let self else { return }
                self.beginProcessing(connection)
                do {
                    let item: TransferItem
                    if outgoing {
                        item = try self.store.enqueueTemporaryFile(temporary, name: name, mimeType: mimeType,
                                                                   expectedSHA256: expectedSHA256)
                        self.itemsChangedHandler?()
                    } else {
                        item = try self.store.saveReceivedFile(temporary, name: name, mimeType: mimeType,
                                                               expectedSHA256: expectedSHA256)
                        self.received(item)
                    }
                    self.sendJSON(connection, status: 201, value: item)
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    self.sendError(connection, status: 400, message: error.localizedDescription)
                }
                self.endProcessing(connection)
            }
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.transferBufferSize) { [weak self] data, _, isComplete, error in
            guard let self, error == nil, let data, !data.isEmpty, !isComplete else {
                try? handle.close()
                try? FileManager.default.removeItem(at: temporary)
                connection.cancel()
                return
            }
            self.touch(connection)
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
                self.touch(connection)
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
            guard let chunk = try handle.read(upToCount: min(Self.transferBufferSize, Int(remaining))), !chunk.isEmpty else {
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
                self.touch(connection)
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
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 413: reason = "Payload Too Large"
        case 415: reason = "Unsupported Media Type"
        case 416: reason = "Range Not Satisfiable"
        case 409: reason = "Conflict"
        case 422: reason = "Unprocessable Content"
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
