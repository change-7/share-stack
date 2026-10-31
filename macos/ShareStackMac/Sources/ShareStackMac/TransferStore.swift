import CryptoKit
import Darwin
import Foundation

struct TransferItem: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let mimeType: String
    let size: Int64
    let sha256: String
    let origin: String
    var state: String
    let createdAt: Date
    var savedPath: String?
    var saveError: String?
    var isShared: Bool? = nil
    var phoneDeliveryPending: Bool? = nil
}

struct SharedFileSummary: Encodable {
    let id: String
    let name: String
    let size: Int64
    let `extension`: String
    let receivedAt: Date
    let state: String
}

struct SharedFilePage: Encodable {
    let items: [SharedFileSummary]
    let nextOffset: Int?
    let pendingImportCount: Int
}

struct SharedFileInfo: Encodable {
    let id: String
    let name: String
    let size: Int64
    let `extension`: String
    let mimeType: String
    let sha256: String
    let receivedAt: Date
    let state: String
    let isReadable: Bool
    let reason: String?
}

struct SharedFileChunk: Encodable {
    let id: String
    let content: String
    let offset: Int64
    let nextOffset: Int64
    let bytesRead: Int
    let sizeBytes: Int64
    let hasMore: Bool
}

struct AIExchangeFile: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let mimeType: String
    let size: Int64
    let sha256: String
    let createdAt: Date
    var aiReadAllowed: Bool? = nil
    var sourceItemID: String? = nil
    var phoneDeliveryPending: Bool? = nil
}

struct LibraryItem: Identifiable, Equatable {
    let id: String
    let name: String
    let mimeType: String
    let size: Int64
    let createdAt: Date
    let transfer: TransferItem?
    let exchange: AIExchangeFile?

    static func combine(inbox: [TransferItem], saved: [TransferItem], exchange: [AIExchangeFile]) -> [LibraryItem] {
        var transfersByID: [String: TransferItem] = [:]
        for item in inbox + saved { transfersByID[item.id] = item }
        let transfers = Array(transfersByID.values)
        var copiesBySource: [String: [AIExchangeFile]] = [:]
        for file in exchange {
            if let sourceID = file.sourceItemID { copiesBySource[sourceID, default: []].append(file) }
        }
        var linkedCopyIDs = Set<String>()
        let transferRows = transfers.map { item in
            let copy = copiesBySource[item.id]?.first { $0.sha256 == item.sha256 && $0.size == item.size }
            if let copy { linkedCopyIDs.insert(copy.id) }
            return LibraryItem(id: item.id, name: item.name, mimeType: item.mimeType, size: item.size,
                               createdAt: item.createdAt, transfer: item, exchange: copy)
        }
        let rows = transferRows + exchange.filter { !linkedCopyIDs.contains($0.id) }.map { file in
            LibraryItem(id: file.id, name: file.name, mimeType: file.mimeType, size: file.size,
                        createdAt: file.createdAt, transfer: nil, exchange: file)
        }
        return rows.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
    }
}

final class AIReadPreparation: @unchecked Sendable {
    static let delay: TimeInterval = 0.7
    private let lock = NSLock()
    private let now: () -> TimeInterval
    private let deadline: TimeInterval
    private var cancelled = false
    private var committedID: String?
    let permissionKey: String?
    let permissionRevision: UInt64

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         permissionKey: String? = nil, permissionRevision: UInt64 = 0) {
        self.permissionKey = permissionKey
        self.permissionRevision = permissionRevision
        self.now = now
        deadline = now() + Self.delay
    }

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }

    @discardableResult func cancel() -> String? {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        return committedID
    }

    func whileCurrent(_ body: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try body()
    }

    func commit(_ body: () throws -> AIExchangeFile, requireDelay: Bool = true) throws -> AIExchangeFile {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        guard !requireDelay || now() >= deadline else { throw TransferStore.StoreError.aiPreparationWaiting }
        let file = try body()
        committedID = file.id
        return file
    }
}

struct PhoneAIReadRequest: Codable, Equatable {
    let id: String
    let revision: Int64
    let allowed: Bool
    var sourceID: String?
    var sha256: String?
    var locallyRevoked: Bool? = nil
}

struct PhoneAIReadStatus: Encodable {
    let id: String
    let revision: Int64
    let allowed: Bool
    let ready: Bool
}

private struct AIExchangeIndex: Codable {
    var aiReadEnabled = true
    var files: [AIExchangeFile] = []
    var retiredIDs: Set<String> = []
    var phoneIntents: [String: PhoneAIReadRequest] = [:]

    private enum CodingKeys: String, CodingKey { case aiReadEnabled, files, retiredIDs, phoneIntents }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        aiReadEnabled = try values.decodeIfPresent(Bool.self, forKey: .aiReadEnabled) ?? true
        files = try values.decodeIfPresent([AIExchangeFile].self, forKey: .files) ?? []
        retiredIDs = try values.decodeIfPresent(Set<String>.self, forKey: .retiredIDs) ?? []
        phoneIntents = try values.decodeIfPresent([String: PhoneAIReadRequest].self, forKey: .phoneIntents) ?? [:]
    }
}

struct ReceiptSettings: Codable {
    enum Mode: String, Codable {
        case inbox
        case automatic
    }

    var mode: Mode = .inbox
    var folderPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads/Share Stack", isDirectory: true).path
    var inboxFolderPath: String? = nil
}

struct UploadSession: Codable {
    let id: String
    let name: String
    let mimeType: String
    let size: Int64
    let sha256: String
}

struct TransferEvent: Encodable {
    let sequence: Int
    let type: String
    let itemID: String
    let createdAt: Date
    let error: String?
}

struct TransferEventPage: Encodable {
    let streamID: String
    let nextCursor: Int
    let hasMore: Bool
    let events: [TransferEvent]
}

struct BatchReceiptResult: Encodable {
    struct Failure: Encodable {
        let id: String
        let error: String
    }
    var saved: [TransferItem] = []
    var failed: [Failure] = []
}

struct UploadStatus: Encodable {
    let id: String
    let offset: Int64
    let complete: Bool
}

struct UploadRange {
    let start: Int64
    let end: Int64
    let total: Int64
    var length: Int64 { end - start + 1 }

    static func parse(_ value: String, fileSize: Int64? = nil) -> UploadRange? {
        if let fileSize, value.hasPrefix("bytes=") {
            return parse("bytes \(value.dropFirst(6))/\(fileSize)")
        }
        guard value.hasPrefix("bytes ") else { return nil }
        let parts = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let total = Int64(parts[1]), total > 0,
              fileSize == nil || fileSize == total else { return nil }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              start >= 0, end >= start, end < total else { return nil }
        return UploadRange(start: start, end: end, total: total)
    }
}

final class UploadChunkWriter: @unchecked Sendable {
    private let store: TransferStore
    private let id: String
    private let range: UploadRange
    private let handle: FileHandle
    private let lock = NSLock()
    private var written: Int64 = 0
    private var closed = false

    fileprivate init(store: TransferStore, id: String, range: UploadRange, handle: FileHandle) {
        self.store = store
        self.id = id
        self.range = range
        self.handle = handle
    }

    func append(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, !data.isEmpty, Int64(data.count) <= range.length - written else {
            throw TransferStore.StoreError.invalidUploadRange
        }
        try handle.write(contentsOf: data)
        written += Int64(data.count)
    }

    func finish() throws -> UploadStatus {
        lock.lock()
        guard !closed, written == range.length else {
            lock.unlock()
            throw TransferStore.StoreError.invalidUploadRange
        }
        do {
            try handle.close()
        } catch {
            closed = true
            lock.unlock()
            store.cancelUploadChunk(id)
            throw error
        }
        closed = true
        lock.unlock()
        store.finishUploadChunk(id)
        return UploadStatus(id: id, offset: range.end + 1, complete: false)
    }

    func cancel() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        try? handle.close()
        lock.unlock()
        store.cancelUploadChunk(id)
    }

    deinit { cancel() }
}

// Mutable state is protected by lock; file paths and FileManager are shared safely across queues.
final class TransferStore: @unchecked Sendable {
    static let maximumItemSize: Int64 = 20 * 1024 * 1024 * 1024
    /// 이 기간 동안 진행되지 않은 이어받기 세션은 임시 파일과 함께 정리한다.
    private static let staleUploadAge: TimeInterval = 24 * 60 * 60

    private struct ExchangeFingerprint: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
    }

    private let fileManager = FileManager.default
    private let root: URL
    private let itemsURL: URL
    private let temporaryURL: URL
    private let uploadsURL: URL
    private let uploadSessionsURL: URL
    private let aiExchangeURL: URL
    private let aiExchangeIndexURL: URL
    private var inboxURL: URL
    private let settingsURL: URL
    private var items: [TransferItem]
    private var uploads: [String: UploadSession]
    private var activeUploadChunks = Set<String>()
    private var settings: ReceiptSettings
    private var aiExchangeIndex: AIExchangeIndex
    private let phoneIntentLock = NSLock()
    private var phonePreparations: [String: AIReadPreparation] = [:]
    private let aiPermissionLock = NSLock()
    private var deniedAIIDs = Set<String>()
    private var aiReadSources: [String: String] = [:]
    private var aiReadRevisions: [String: UInt64] = [:]
    private var verifiedExchangeFiles: [String: ExchangeFingerprint] = [:]
    private let eventStreamID = UUID().uuidString.lowercased()
    private var events: [TransferEvent] = []
    private var eventSequence = 0
    private let lock = NSLock()
    private let shareImportQueue = DispatchQueue(label: "com.pdg.sharestack.share-import", qos: .utility)
    private var isImportingShares = false
    var sharedItemsChangedHandler: (() -> Void)?

    init(rootDirectory: URL? = nil) throws {
        let support = try rootDirectory ?? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        root = (rootDirectory == nil ? support.appendingPathComponent("ShareStackMac", isDirectory: true) : support)
            .standardizedFileURL.resolvingSymlinksInPath()
        itemsURL = root.appendingPathComponent("items.json")
        temporaryURL = root.appendingPathComponent("temporary", isDirectory: true)
        uploadsURL = root.appendingPathComponent("uploads", isDirectory: true)
        uploadSessionsURL = root.appendingPathComponent("uploads.json")
        aiExchangeURL = root.appendingPathComponent("AI Exchange", isDirectory: true)
        aiExchangeIndexURL = root.appendingPathComponent("AI Exchange", isDirectory: true).appendingPathComponent("index.json")
        inboxURL = root.appendingPathComponent("inbox-temporary", isDirectory: true)
        settingsURL = root.appendingPathComponent("receipt-settings.json")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: uploadsURL, withIntermediateDirectories: true)
        let payloadDirectory = root.appendingPathComponent("payloads", isDirectory: true)
        try fileManager.createDirectory(at: payloadDirectory, withIntermediateDirectories: true)
        try Self.createPrivateDirectory(aiExchangeURL)
        if fileManager.fileExists(atPath: aiExchangeIndexURL.path) {
            guard Self.isRegularFileWithoutSymlink(aiExchangeIndexURL) else { throw StoreError.exchangeUnavailable }
            aiExchangeIndex = try JSONDecoder().decode(AIExchangeIndex.self, from: Data(contentsOf: aiExchangeIndexURL))
            guard Self.isValidAIExchangeIndex(aiExchangeIndex) else { throw StoreError.exchangeUnavailable }
            guard chmod(aiExchangeIndexURL.path, mode_t(0o600)) == 0 else { throw StoreError.exchangeUnavailable }
        } else {
            aiExchangeIndex = AIExchangeIndex()
        }
        if fileManager.fileExists(atPath: itemsURL.path) {
            items = try JSONDecoder().decode([TransferItem].self, from: Data(contentsOf: itemsURL))
                .filter { $0.state != "delivered" && ($0.state != "saved" || $0.isShared == true) }
        } else {
            items = []
        }
        if fileManager.fileExists(atPath: uploadSessionsURL.path) {
            uploads = try JSONDecoder().decode([String: UploadSession].self, from: Data(contentsOf: uploadSessionsURL))
        } else {
            uploads = [:]
        }
        if fileManager.fileExists(atPath: settingsURL.path) {
            settings = try JSONDecoder().decode(ReceiptSettings.self, from: Data(contentsOf: settingsURL))
        } else {
            settings = ReceiptSettings()
        }
        if let path = settings.inboxFolderPath {
            inboxURL = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            try fileManager.createDirectory(at: inboxURL, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        }
        for file in (try? fileManager.contentsOfDirectory(at: temporaryURL, includingPropertiesForKeys: nil)) ?? [] {
            try? fileManager.removeItem(at: file)
        }
        for file in (try? fileManager.contentsOfDirectory(at: uploadsURL, includingPropertiesForKeys: nil)) ?? []
        where file.lastPathComponent.contains(".finalizing-") {
            try? fileManager.removeItem(at: file)
        }
        for file in aiExchangeIndex.files { aiReadSources[file.id] = file.sourceItemID ?? file.id }
        pruneStaleUploads()
        pruneExchangeOrphans()
    }

    /// 앱이 꺼져 있던 사이 남은 이어받기 세션과 고아 임시 파일을 정리한다.
    private func pruneStaleUploads() {
        let cutoff = Date().addingTimeInterval(-Self.staleUploadAge)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let files = (try? fileManager.contentsOfDirectory(
            at: uploadsURL,
            includingPropertiesForKeys: Array(keys)
        )) ?? []
        var parts: [String: URL] = [:]
        for file in files {
            let name = file.lastPathComponent
            guard name.hasSuffix(".part"), !name.contains(".finalizing-") else { continue }
            parts[String(name.dropLast(".part".count))] = file
        }

        var changed = false
        for (id, _) in Array(uploads) {
            guard let part = parts.removeValue(forKey: id) else {
                uploads.removeValue(forKey: id)
                changed = true
                continue
            }
            let modified = (try? part.resourceValues(forKeys: keys).contentModificationDate) ?? Date()
            if modified < cutoff {
                try? fileManager.removeItem(at: part)
                uploads.removeValue(forKey: id)
                changed = true
            }
        }
        for (_, orphan) in parts {
            try? fileManager.removeItem(at: orphan)
        }
        if changed { try? persistUploads() }
    }

    func makeTemporaryFile() throws -> URL {
        let url = temporaryURL.appendingPathComponent(UUID().uuidString.lowercased())
        guard fileManager.createFile(atPath: url.path, contents: nil) else {
            throw StoreError.cannotCreateFile
        }
        return url
    }

    func saveReceivedFile(_ temporaryFile: URL, name: String, mimeType: String, expectedSHA256: String,
                          phoneDeliveryPending: Bool = false) throws -> TransferItem {
        try saveReceivedFile(temporaryFile, name: name, mimeType: mimeType,
                             expectedSHA256: expectedSHA256, computedSHA256: nil, receivedAt: Date(),
                             phoneDeliveryPending: phoneDeliveryPending)
    }

    private func saveReceivedFile(_ temporaryFile: URL, name: String, mimeType: String,
                                  expectedSHA256: String, computedSHA256: String?, receivedAt: Date,
                                  phoneDeliveryPending: Bool = false) throws -> TransferItem {
        guard expectedSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            try? fileManager.removeItem(at: temporaryFile)
            throw StoreError.checksumMismatch
        }
        let size = try Self.fileSize(temporaryFile)
        guard size <= Self.maximumItemSize else {
            try? fileManager.removeItem(at: temporaryFile)
            throw StoreError.itemTooLarge
        }
        let sha256: String
        if let computedSHA256 {
            sha256 = computedSHA256
        } else {
            sha256 = try Self.sha256(temporaryFile)
        }
        guard sha256 == expectedSHA256 else {
            try? fileManager.removeItem(at: temporaryFile)
            throw StoreError.checksumMismatch
        }
        lock.lock()
        defer { lock.unlock() }
        if let duplicate = receivedItemLocked(sha256: sha256) {
            try? fileManager.removeItem(at: temporaryFile)
            if phoneDeliveryPending, let index = items.firstIndex(where: { $0.id == duplicate.id }) {
                items[index].phoneDeliveryPending = true
                do { try persist() }
                catch { items[index] = duplicate; throw error }
                return items[index]
            }
            return duplicate
        }
        return try insertReceivedLocked(temporaryFile, name: name, mimeType: mimeType,
                                        size: size, sha256: sha256, receivedAt: receivedAt,
                                        phoneDeliveryPending: phoneDeliveryPending)
    }

    func beginUpload(_ session: UploadSession) throws -> UploadStatus {
        lock.lock()
        defer { lock.unlock() }
        guard session.id == session.sha256,
              session.id.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              session.size >= 0, session.size <= Self.maximumItemSize,
              !session.name.isEmpty, !session.mimeType.isEmpty,
              !activeUploadChunks.contains(session.id) else { throw StoreError.invalidUpload }
        if let existing = receivedItemLocked(sha256: session.sha256) {
            try removeUploadLocked(session.id)
            return UploadStatus(id: session.id, offset: existing.size, complete: true)
        }
        if let existing = uploads[session.id] {
            guard existing.name == session.name, existing.mimeType == session.mimeType,
                  existing.size == session.size, existing.sha256 == session.sha256 else {
                throw StoreError.invalidUpload
            }
            if !fileManager.fileExists(atPath: uploadURL(session.id).path) {
                guard fileManager.createFile(atPath: uploadURL(session.id).path, contents: nil) else {
                    throw StoreError.cannotCreateFile
                }
            }
        } else {
            let partial = uploadURL(session.id)
            if fileManager.fileExists(atPath: partial.path) { try fileManager.removeItem(at: partial) }
            guard fileManager.createFile(atPath: partial.path, contents: nil) else { throw StoreError.cannotCreateFile }
            uploads[session.id] = session
            do {
                try persistUploads()
            } catch {
                uploads.removeValue(forKey: session.id)
                try? fileManager.removeItem(at: partial)
                throw error
            }
        }
        let offset = try Self.fileSize(uploadURL(session.id))
        guard offset <= session.size else { throw StoreError.invalidUpload }
        return UploadStatus(id: session.id, offset: offset, complete: false)
    }

    func beginUploadChunk(_ id: String, range: UploadRange) throws -> UploadChunkWriter {
        lock.lock()
        defer { lock.unlock() }
        guard let session = uploads[id], range.total == session.size, range.start >= 0,
              range.end >= range.start, range.end < session.size,
              !activeUploadChunks.contains(id) else { throw StoreError.invalidUploadRange }
        let partial = uploadURL(id)
        guard try Self.fileSize(partial) == range.start else { throw StoreError.invalidUploadRange }
        let handle = try FileHandle(forWritingTo: partial)
        do {
            try handle.seekToEnd()
        } catch {
            try? handle.close()
            throw error
        }
        activeUploadChunks.insert(id)
        return UploadChunkWriter(store: self, id: id, range: range, handle: handle)
    }

    fileprivate func finishUploadChunk(_ id: String) {
        lock.lock()
        activeUploadChunks.remove(id)
        lock.unlock()
    }

    fileprivate func cancelUploadChunk(_ id: String) {
        lock.lock()
        activeUploadChunks.remove(id)
        lock.unlock()
    }

    func finishUpload(_ id: String) throws -> TransferItem {
        let partial = uploadURL(id)
        lock.lock()
        guard !activeUploadChunks.contains(id) else {
            lock.unlock()
            throw StoreError.invalidUploadRange
        }
        if let existing = receivedItemLocked(sha256: id) {
            try? removeUploadLocked(id)
            lock.unlock()
            return existing
        }
        guard let session = uploads[id] else {
            lock.unlock()
            throw StoreError.invalidUploadRange
        }
        // Claim the completed part file under the lock so a concurrent beginUpload
        // or another finish cannot unlink it while it is being hashed.
        let claimed = uploadsURL.appendingPathComponent(id + ".finalizing-" + UUID().uuidString)
        do {
            guard try Self.fileSize(partial) == session.size else {
                throw StoreError.invalidUploadRange
            }
            try fileManager.moveItem(at: partial, to: claimed)
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()

        do {
            try Self.synchronize(claimed)
            let sha256 = try Self.sha256(claimed)
            guard sha256 == session.sha256 else { throw StoreError.checksumMismatch }

            lock.lock()
            defer { lock.unlock() }
            if let existing = receivedItemLocked(sha256: sha256) {
                try? fileManager.removeItem(at: claimed)
                try? removeUploadLocked(id)
                return existing
            }
            guard uploads[id] != nil else { throw StoreError.invalidUploadRange }
            let item = try insertReceivedLocked(claimed, name: session.name, mimeType: session.mimeType,
                                                size: session.size, sha256: sha256)
            try? removeUploadLocked(id)
            return item
        } catch {
            lock.lock()
            if uploads[id] != nil, fileManager.fileExists(atPath: claimed.path) {
                try? fileManager.removeItem(at: partial)
                try? fileManager.moveItem(at: claimed, to: partial)
            } else {
                try? fileManager.removeItem(at: claimed)
            }
            lock.unlock()
            throw error
        }
    }

    private func insertReceivedLocked(_ temporaryFile: URL, name: String, mimeType: String,
                                      size: Int64, sha256: String, receivedAt: Date = Date(),
                                      phoneDeliveryPending: Bool = false) throws -> TransferItem {
        guard Self.isRegularDirectoryWithoutSymlink(inboxURL) else { throw StoreError.invalidTemporaryFolder }
        let id = UUID().uuidString.lowercased()
        let destination = inboxURL.appendingPathComponent(id)
        try fileManager.moveItem(at: temporaryFile, to: destination)
        let item = TransferItem(
            id: id,
            name: Self.safeName(name),
            mimeType: mimeType,
            size: size,
            sha256: sha256,
            origin: "galaxy",
            state: "awaitingAcceptance",
            createdAt: receivedAt,
            isShared: true,
            phoneDeliveryPending: phoneDeliveryPending ? true : nil
        )
        items.insert(item, at: 0)
        do {
            try persist()
        } catch {
            items.removeAll { $0.id == id }
            try? fileManager.moveItem(at: destination, to: temporaryFile)
            throw error
        }
        recordEventLocked("file.received", itemID: id)
        if settings.mode == .automatic {
            do {
                return try acceptReceivedItemLocked(id)
            } catch {
                recordEventLocked("file.save_failed", itemID: id, error: error.localizedDescription)
                if let index = items.firstIndex(where: { $0.id == id }) {
                    items[index].saveError = error.localizedDescription
                    try? persist()
                    return items[index]
                }
                throw error
            }
        }
        return item
    }

    func receiptSettings() -> ReceiptSettings {
        lock.lock()
        defer { lock.unlock() }
        var value = settings
        value.inboxFolderPath = inboxURL.path
        return value
    }

    @discardableResult
    func updateReceiptSettings(_ value: ReceiptSettings) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        let folder = URL(fileURLWithPath: value.folderPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let dataPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard folder.path != dataPath, !folder.path.hasPrefix(dataPath + "/") else {
            throw StoreError.invalidSaveFolder
        }
        var updated = value
        updated.folderPath = folder.path
        let requestedPath = value.inboxFolderPath ?? root.appendingPathComponent("inbox-temporary").path
        guard requestedPath.hasPrefix("/") else { throw StoreError.invalidTemporaryFolder }
        let requested = URL(fileURLWithPath: requestedPath, isDirectory: true).standardizedFileURL
        let target = requested.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(requested.lastPathComponent, isDirectory: true)
        guard folder.path != target.path, !folder.path.hasPrefix(target.path + "/") else {
            throw StoreError.invalidSaveFolder
        }
        if target.path == inboxURL.standardizedFileURL.path {
            updated.inboxFolderPath = inboxURL.path
            try JSONEncoder().encode(updated).write(to: settingsURL, options: .atomic)
            settings = updated
            return "설정 저장됨"
        }
        let defaultInbox = root.appendingPathComponent("inbox-temporary").standardizedFileURL
        guard target.path != dataPath,
              (!target.path.hasPrefix(dataPath + "/") || target.path == defaultInbox.path),
              !target.path.hasPrefix(inboxURL.standardizedFileURL.path + "/"),
              Self.isRegularDirectoryWithoutSymlink(target.deletingLastPathComponent()) else {
            throw StoreError.invalidTemporaryFolder
        }

        // Own a fresh subdirectory so existing files in the selected location cannot be overwritten.
        var destination = target
        var suffix = 0
        while mkdir(destination.path, 0o700) != 0 {
            guard errno == EEXIST else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            suffix += 1
            destination = target.deletingLastPathComponent()
                .appendingPathComponent("\(target.lastPathComponent) (\(suffix))", isDirectory: true)
        }
        var originals: [URL] = []
        do {
            guard folder.path != destination.path, !folder.path.hasPrefix(destination.path + "/") else {
                throw StoreError.invalidSaveFolder
            }
            for item in items where Self.isAwaitingAcceptance(item) {
                let source = storedURL(item)
                guard UUID(uuidString: item.id) != nil, Self.isRegularFileWithoutSymlink(source),
                      (try? Self.fileSize(source)) == item.size else {
                    throw StoreError.sharedFileUnavailable
                }
                let copy = destination.appendingPathComponent(item.id)
                try fileManager.copyItem(at: source, to: copy)
                guard Self.isRegularFileWithoutSymlink(copy), try Self.sha256(copy) == item.sha256 else {
                    throw StoreError.checksumMismatch
                }
                try Self.synchronize(copy)
                originals.append(source)
            }
            updated.inboxFolderPath = destination.path
            try JSONEncoder().encode(updated).write(to: settingsURL, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        inboxURL = destination
        settings = updated
        var remaining = 0
        for source in originals {
            do { try fileManager.removeItem(at: source) }
            catch { remaining += 1 }
        }
        return remaining == 0 ? "임시 보관 폴더 변경됨" : "폴더 변경됨 · 이전 위치에 남은 복사본 \(remaining)개"
    }

    func inboxItems() -> [TransferItem] {
        lock.lock()
        let result = items.filter { Self.isAwaitingAcceptance($0) }
        lock.unlock()
        scheduleShareImports()
        return result
    }

    @discardableResult
    func acceptReceivedItem(_ id: String) throws -> TransferItem {
        lock.lock()
        defer { lock.unlock() }
        if let existing = items.first(where: { $0.id == id && $0.origin == "galaxy" && $0.state == "saved" }) {
            return existing
        }
        do {
            return try acceptReceivedItemLocked(id)
        } catch {
            recordEventLocked("file.save_failed", itemID: id, error: error.localizedDescription)
            throw error
        }
    }

    func acceptAllReceivedItems() -> BatchReceiptResult {
        let pending = inboxItems()
        var result = BatchReceiptResult()
        for item in pending {
            do {
                result.saved.append(try acceptReceivedItem(item.id))
            } catch {
                result.failed.append(.init(id: item.id, error: error.localizedDescription))
            }
        }
        return result
    }

    func eventPage(after cursor: Int?, streamID: String?) throws -> TransferEventPage {
        lock.lock()
        defer { lock.unlock() }
        let firstCursor = (events.first?.sequence ?? (eventSequence + 1)) - 1
        if let cursor {
            guard streamID == eventStreamID, cursor >= firstCursor, cursor <= eventSequence else {
                throw StoreError.eventCursorExpired
            }
        }
        let page = Array(events.filter { $0.sequence > (cursor ?? firstCursor) }.prefix(100))
        let next = page.last?.sequence ?? cursor ?? eventSequence
        return TransferEventPage(streamID: eventStreamID, nextCursor: next,
                                 hasMore: next < eventSequence, events: page)
    }

    private func recordEventLocked(_ type: String, itemID: String, error: String? = nil) {
        eventSequence += 1
        events.append(TransferEvent(sequence: eventSequence, type: type, itemID: itemID, createdAt: Date(), error: error))
        if events.count > 200 { events.removeFirst(events.count - 200) }
    }

    private func acceptReceivedItemLocked(_ id: String) throws -> TransferItem {
        guard let index = items.firstIndex(where: { $0.id == id && Self.isAwaitingAcceptance($0) }) else {
            throw StoreError.itemNotInInbox
        }
        let previous = items[index]
        let source = storedURL(previous)
        let folder = URL(fileURLWithPath: settings.folderPath, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let filename = URL(fileURLWithPath: previous.name)
        let stem = filename.deletingPathExtension().lastPathComponent
        let suffix = filename.pathExtension.isEmpty ? "" : "." + filename.pathExtension
        var counter = 0
        var destination: URL
        while true {
            let name = counter == 0 ? previous.name : "\(stem) (\(counter))\(suffix)"
            destination = folder.appendingPathComponent(name)
            do {
                try fileManager.moveItem(at: source, to: destination)
                break
            } catch CocoaError.fileWriteFileExists {
                counter += 1
            }
        }
        var saved = previous
        saved.state = "saved"
        saved.savedPath = destination.path
        saved.saveError = nil
        saved.isShared = true
        items[index] = saved
        do {
            try persist()
        } catch {
            items[index] = previous
            try fileManager.moveItem(at: destination, to: source)
            throw error
        }
        recordEventLocked("file.saved", itemID: id)
        return saved
    }

    func cancelReceivedItem(_ id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let index = items.firstIndex(where: { $0.id == id && (Self.isAwaitingAcceptance($0) || ($0.origin == "galaxy" && $0.state == "saved" && $0.isShared == true)) }) else {
            throw StoreError.itemNotInInbox
        }
        let linked = aiExchangeIndex.files.filter { $0.sourceItemID == id }.map(\.id)
        for fileID in linked { denyAIReadImmediately(fileID) }
        if items[index].state == "saved" {
            let previous = items[index]
            items[index].isShared = false
            items[index].phoneDeliveryPending = false
            do { try persist() } catch { items[index] = previous; throw error }
            recordEventLocked("file.removed", itemID: id)
        } else {
            try removeItemLocked(at: index, eventType: "file.cancelled")
        }
        for fileID in linked { try deleteAIExchangeFileLocked(fileID) }
    }

    func cancelOutgoingItem(_ id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if try finishLibraryPhoneDeliveryLocked(id) {
            recordEventLocked("outbox.cancelled", itemID: id)
            return
        }
        guard let index = items.firstIndex(where: { $0.id == id && $0.origin == "mac" && $0.state == "pending" }) else {
            throw StoreError.itemNotPending
        }
        try removeItemLocked(at: index, eventType: "outbox.cancelled")
    }

    private func removeItemLocked(at index: Int, eventType: String) throws {
        let item = items[index]
        let source = storedURL(item)
        let discarded = temporaryURL.appendingPathComponent(UUID().uuidString)
        let exists = fileManager.fileExists(atPath: source.path)
        if exists { try fileManager.moveItem(at: source, to: discarded) }
        items.remove(at: index)
        do {
            try persist()
        } catch {
            items.insert(item, at: index)
            if exists { try fileManager.moveItem(at: discarded, to: source) }
            throw error
        }
        if exists {
            do {
                try fileManager.removeItem(at: discarded)
            } catch {
                items.insert(item, at: index)
                try fileManager.moveItem(at: discarded, to: source)
                try persist()
                throw error
            }
        }
        recordEventLocked(eventType, itemID: item.id)
    }

    private static func isAwaitingAcceptance(_ item: TransferItem) -> Bool {
        item.origin == "galaxy" && (item.state == "awaitingAcceptance" || item.state == "received")
    }

    private static func isSharedFile(_ item: TransferItem) -> Bool {
        item.origin == "galaxy" && (item.isShared == true || isAwaitingAcceptance(item))
    }

    private func receivedItemLocked(sha256: String) -> TransferItem? {
        items.first { Self.isAwaitingAcceptance($0) && $0.sha256 == sha256 && fileManager.fileExists(atPath: storedURL($0).path) }
    }

    private func storedURL(_ item: TransferItem) -> URL {
        if let path = item.savedPath { return URL(fileURLWithPath: path) }
        if item.state == "awaitingAcceptance" { return inboxURL.appendingPathComponent(item.id) }
        if item.state == "received" {
            let migrated = inboxURL.appendingPathComponent(item.id)
            if fileManager.fileExists(atPath: migrated.path) { return migrated }
        }
        return payloadURL(item.id)
    }

    private func removeUploadLocked(_ id: String) throws {
        guard uploads.removeValue(forKey: id) != nil else { return }
        try? fileManager.removeItem(at: uploadURL(id))
        try persistUploads()
    }

    func enqueueFile(_ source: URL, mimeType: String) throws -> TransferItem {
        let temporary = try makeTemporaryFile()
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        do {
            try fileManager.removeItem(at: temporary)
            try fileManager.copyItem(at: source, to: temporary)
            return try enqueueTemporaryFile(temporary, name: source.lastPathComponent, mimeType: mimeType)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    func importReceivedFile(_ source: URL, mimeType: String, name: String? = nil, expectedSHA256: String? = nil,
                            receivedAt: Date? = nil) throws -> TransferItem {
        let temporary = try makeTemporaryFile()
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        do {
            try fileManager.removeItem(at: temporary)
            try fileManager.copyItem(at: source, to: temporary)
            let checksum = try Self.sha256(temporary)
            if let expectedSHA256, checksum != expectedSHA256 { throw StoreError.checksumMismatch }
            return try saveReceivedFile(temporary, name: name ?? source.lastPathComponent, mimeType: mimeType,
                                        expectedSHA256: checksum, computedSHA256: checksum,
                                        receivedAt: receivedAt ?? Date())
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    func receiveFileData(_ data: Data, name: String, mimeType: String,
                         phoneDeliveryPending: Bool = false) throws -> TransferItem {
        guard Int64(data.count) <= Self.maximumItemSize else { throw StoreError.itemTooLarge }
        let temporary = try makeTemporaryFile()
        do {
            try data.write(to: temporary, options: .atomic)
            let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return try saveReceivedFile(temporary, name: name, mimeType: mimeType, expectedSHA256: checksum,
                                        phoneDeliveryPending: phoneDeliveryPending)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    func enqueueText(_ text: String) throws -> TransferItem {
        let temporary = try makeTemporaryFile()
        do {
            try Data(text.utf8).write(to: temporary)
            return try enqueueTemporaryFile(temporary, name: "Clipboard.txt", mimeType: "text/plain")
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    func enqueueTemporaryFile(_ temporaryFile: URL, name: String, mimeType: String, expectedSHA256: String? = nil) throws -> TransferItem {
        let size = try Self.fileSize(temporaryFile)
        guard size <= Self.maximumItemSize else {
            try? fileManager.removeItem(at: temporaryFile)
            throw StoreError.itemTooLarge
        }
        let sha256 = try Self.sha256(temporaryFile)
        if let expectedSHA256, sha256 != expectedSHA256 {
            try? fileManager.removeItem(at: temporaryFile)
            throw StoreError.checksumMismatch
        }
        lock.lock()
        defer { lock.unlock() }
        if let duplicate = items.first(where: { $0.sha256 == sha256 && $0.origin == "mac" && $0.state != "delivered" }) {
            try? fileManager.removeItem(at: temporaryFile)
            return duplicate
        }
        let id = UUID().uuidString.lowercased()
        let destination = payloadURL(id)
        try fileManager.moveItem(at: temporaryFile, to: destination)
        let item = TransferItem(
            id: id,
            name: Self.safeName(name),
            mimeType: mimeType,
            size: size,
            sha256: sha256,
            origin: "mac",
            state: "pending",
            createdAt: Date()
        )
        items.insert(item, at: 0)
        do {
            try persist()
        } catch {
            items.removeAll { $0.id == id }
            try? fileManager.removeItem(at: destination)
            throw error
        }
        return item
    }

    func queueLibraryItemForPhone(_ id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let index = items.firstIndex(where: { $0.id == id && $0.origin == "galaxy" }) {
            guard sharedFileURL(items[index]) != nil else { throw StoreError.sharedFileUnavailable }
            let previous = items[index]
            items[index].phoneDeliveryPending = true
            do { try persist() } catch { items[index] = previous; throw error }
            return
        }
        if let index = aiExchangeIndex.files.firstIndex(where: { $0.id == id && $0.sourceItemID == nil }) {
            guard Self.exchangeFileExists(aiExchangeIndex.files[index], directory: aiExchangeURL) else { throw StoreError.sharedFileUnavailable }
            let previous = aiExchangeIndex.files[index]
            aiExchangeIndex.files[index].phoneDeliveryPending = true
            do { try persistAIExchangeIndexLocked() } catch { aiExchangeIndex.files[index] = previous; throw error }
            return
        }
        throw StoreError.sharedFileNotFound
    }

    func pendingForGalaxy() -> [TransferItem] {
        lock.lock()
        defer { lock.unlock() }
        let transfers = items.filter {
            $0.origin == "mac" && $0.state == "pending" ||
                $0.phoneDeliveryPending == true && sharedFileURL($0) != nil
        }
        let exchange = aiExchangeIndex.files.filter(isPendingPhoneDelivery).map(Self.phoneTransferItem)
        return (transfers + exchange).sorted { $0.createdAt > $1.createdAt }
    }

    private func isPendingPhoneDelivery(_ file: AIExchangeFile) -> Bool {
        file.sourceItemID == nil && file.phoneDeliveryPending != false && Self.exchangeFileExists(file, directory: aiExchangeURL)
    }

    private static func phoneTransferItem(_ file: AIExchangeFile) -> TransferItem {
        TransferItem(id: file.id, name: file.name, mimeType: file.mimeType, size: file.size,
                     sha256: file.sha256, origin: "mac", state: "pending", createdAt: file.createdAt)
    }

    func fileURL(for id: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let item = items.first(where: { $0.id == id }) else {
            guard let file = aiExchangeIndex.files.first(where: { $0.id == id && isPendingPhoneDelivery($0) }) else { return nil }
            return aiExchangeURL.appendingPathComponent(file.id)
        }
        let url = storedURL(item)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func item(for id: String) -> TransferItem? {
        lock.lock()
        defer { lock.unlock() }
        if let item = items.first(where: { $0.id == id && ($0.phoneDeliveryPending == true || $0.state != "saved" && $0.state != "delivered") }) { return item }
        return aiExchangeIndex.files.first { $0.id == id && isPendingPhoneDelivery($0) }.map(Self.phoneTransferItem)
    }

    func sharedFiles(offset: Int, limit: Int) -> SharedFilePage {
        scheduleShareImports()
        lock.lock()
        let received = items.filter(Self.isSharedFile)
        let pageItems = Array(received.dropFirst(offset).prefix(limit)).map { item in
            SharedFileSummary(id: item.id, name: item.name, size: item.size,
                              extension: URL(fileURLWithPath: item.name).pathExtension.lowercased(),
                              receivedAt: item.createdAt, state: sharedFileURL(item) == nil ? "unavailable" : item.state)
        }
        let next = offset + pageItems.count < received.count ? offset + pageItems.count : nil
        lock.unlock()
        return SharedFilePage(items: pageItems, nextOffset: next, pendingImportCount: pendingShareImportCount())
    }

    func sharedFileInfo(_ id: String) throws -> SharedFileInfo {
        lock.lock()
        defer { lock.unlock() }
        guard let item = items.first(where: { $0.id == id && Self.isSharedFile($0) }) else {
            throw StoreError.sharedFileNotFound
        }
        let extensionName = URL(fileURLWithPath: item.name).pathExtension.lowercased()
        let exists = sharedFileURL(item) != nil
        let textType = Self.isTextFile(name: item.name, mimeType: item.mimeType)
        return SharedFileInfo(id: item.id, name: item.name, size: item.size, extension: extensionName,
                              mimeType: item.mimeType, sha256: item.sha256, receivedAt: item.createdAt,
                              state: exists ? item.state : "unavailable", isReadable: exists && textType,
                              reason: !exists ? "파일이 삭제되었거나 안전하게 읽을 수 없습니다" : (textType ? nil : "텍스트 파일 형식만 읽을 수 있습니다"))
    }

    func readSharedFile(_ id: String, offset: Int64, limit: Int) throws -> SharedFileChunk {
        lock.lock()
        guard let item = items.first(where: { $0.id == id && Self.isSharedFile($0) }),
              let url = sharedFileURL(item) else {
            lock.unlock()
            throw StoreError.sharedFileNotFound
        }
        guard Self.isTextFile(name: item.name, mimeType: item.mimeType) else {
            lock.unlock()
            throw StoreError.unsupportedSharedFile
        }
        let size = item.size
        lock.unlock()
        guard offset >= 0, offset <= size, limit > 0, limit <= 32768 else { throw StoreError.invalidSharedFileRange }

        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw StoreError.sharedFileUnavailable }
        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0,
              fileInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), Int64(fileInfo.st_size) == size else {
            close(descriptor)
            throw StoreError.sharedFileUnavailable
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let bytes = try handle.read(upToCount: min(limit, Int(size - offset))) ?? Data()
        if let first = bytes.first, first & 0b1100_0000 == 0b1000_0000 { throw StoreError.invalidSharedFileRange }
        guard offset == size || !bytes.isEmpty else { throw StoreError.sharedFileUnavailable }
        let (content, bytesRead) = try Self.decodeUTF8Chunk(bytes)
        guard offset == size || bytesRead > 0 else { throw StoreError.sharedFileUnavailable }
        let next = offset + Int64(bytesRead)
        return SharedFileChunk(id: id, content: content, offset: offset, nextOffset: next,
                               bytesRead: bytesRead, sizeBytes: size, hasMore: next < size)
    }

    func workspaceStore() throws -> WorkspaceStore {
        try WorkspaceStore(root: root.appendingPathComponent("Workspaces", isDirectory: true), enabled: { [weak self] in self?.aiExchangeEnabled() ?? false })
    }

    func aiExchangeEnabled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return aiExchangeIndex.aiReadEnabled
    }

    func setAIExchangeEnabled(_ enabled: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        let previous = aiExchangeIndex.aiReadEnabled
        aiExchangeIndex.aiReadEnabled = enabled
        do { try persistAIExchangeIndexLocked() }
        catch {
            aiExchangeIndex.aiReadEnabled = previous
            throw error
        }
        if !enabled { verifiedExchangeFiles.removeAll() }
    }

    func aiExchangeItems() -> [AIExchangeFile] {
        lock.lock()
        defer { lock.unlock() }
        return aiExchangeIndex.files.filter { Self.exchangeFileExists($0, directory: aiExchangeURL) }
    }

    func savedReceivedItems() -> [TransferItem] {
        lock.lock()
        defer { lock.unlock() }
        return items.filter {
            $0.origin == "galaxy" && $0.state == "saved" && $0.isShared == true && sharedFileURL($0) != nil
        }
    }

    func addInboxFileToAIExchange(_ id: String) throws -> AIExchangeFile {
        let item = try exchangeSource(id)
        return try registerAIExchangeFile(name: item.0.name, mimeType: item.0.mimeType,
                                          sourceURL: item.1, expectedSize: item.0.size,
                                          expectedSHA256: item.0.sha256, sourceItemID: id)
    }

    private func exchangeSource(_ id: String) throws -> (TransferItem, URL) {
        lock.lock()
        defer { lock.unlock() }
        guard let item = items.first(where: {
            $0.id == id && $0.origin == "galaxy" &&
                (Self.isAwaitingAcceptance($0) || $0.state == "saved" && $0.isShared == true)
        }) else { throw StoreError.itemNotInInbox }
        return (item, storedURL(item))
    }

    func makeAIReadPreparation(sourceID: String?, fileID: String?) -> AIReadPreparation {
        aiPermissionLock.lock()
        defer { aiPermissionLock.unlock() }
        let key = sourceID ?? fileID.map { aiReadSources[$0] ?? $0 }
        return AIReadPreparation(permissionKey: key, permissionRevision: key.map { aiReadRevisions[$0, default: 0] } ?? 0)
    }

    func invalidateAIReadPreparation(sourceID: String) {
        aiPermissionLock.lock()
        aiReadRevisions[sourceID, default: 0] += 1
        aiPermissionLock.unlock()
    }

    func denyAIReadImmediately(_ id: String) {
        aiPermissionLock.lock()
        let id = id.lowercased()
        deniedAIIDs.insert(id)
        aiReadRevisions[aiReadSources[id] ?? id, default: 0] += 1
        aiPermissionLock.unlock()
    }

    // Called with aiPermissionLock held through the grant's durable commit.
    private func validateAIPreparationLocked(_ preparation: AIReadPreparation) throws {
        if let key = preparation.permissionKey, aiReadRevisions[key, default: 0] != preparation.permissionRevision {
            throw CancellationError()
        }
    }

    private func isAIDenied(_ id: String) -> Bool {
        aiPermissionLock.lock()
        defer { aiPermissionLock.unlock() }
        return deniedAIIDs.contains(id.lowercased())
    }

    func revokeAIRead(_ id: String, preparation: AIReadPreparation? = nil) throws {
        if preparation == nil { denyAIReadImmediately(id) }
        func commit() throws -> AIExchangeFile {
            lock.lock()
            defer { lock.unlock() }
            guard let index = aiExchangeIndex.files.firstIndex(where: { $0.id == id.lowercased() }) else {
                throw StoreError.sharedFileNotFound
            }
            denyAIReadImmediately(id)
            aiExchangeIndex.files[index].aiReadAllowed = false
            markPhoneConsentRevokedLocked(sourceID: aiExchangeIndex.files[index].sourceItemID)
            verifiedExchangeFiles.removeValue(forKey: id.lowercased())
            try persistAIExchangeIndexLocked()
            return aiExchangeIndex.files[index]
        }
        if let preparation { _ = try preparation.commit(commit, requireDelay: false) }
        else { _ = try commit() }
    }

    private func markPhoneConsentRevokedLocked(sourceID: String?) {
        guard let sourceID else { return }
        for id in Array(aiExchangeIndex.phoneIntents.keys) where aiExchangeIndex.phoneIntents[id]?.sourceID == sourceID {
            aiExchangeIndex.phoneIntents[id]?.locallyRevoked = true
        }
    }

    func revokePhoneConsentFromMac(sourceID: String, preparation: AIReadPreparation) throws {
        try preparation.whileCurrent {
            lock.lock()
            defer { lock.unlock() }
            invalidateAIReadPreparation(sourceID: sourceID)
            markPhoneConsentRevokedLocked(sourceID: sourceID)
            try persistAIExchangeIndexLocked()
        }
    }

    private func requireAIRead(_ id: String) throws {
        guard !isAIDenied(id) else { throw StoreError.sharedFileNotFound }
        lock.lock()
        defer { lock.unlock() }
        guard aiExchangeIndex.aiReadEnabled else { throw StoreError.aiExchangeDisabled }
        guard aiExchangeIndex.files.contains(where: { $0.id == id && $0.aiReadAllowed == true }) else {
            throw StoreError.sharedFileNotFound
        }
    }

    func prepareAIRead(sourceID: String?, fileID: String?, preparation: AIReadPreparation,
                       progress: (Double) -> Void = { _ in }) throws -> AIExchangeFile {
        try preparation.check()
        if let fileID {
            lock.lock()
            let candidate = aiExchangeIndex.files.first { $0.id == fileID }
            lock.unlock()
            guard var file = candidate else { throw StoreError.sharedFileNotFound }
            if let sourceID {
                let source = try exchangeSource(sourceID).0
                guard file.sourceItemID == sourceID, file.sha256 == source.sha256, file.size == source.size else {
                    throw StoreError.sharedFileUnavailable
                }
            }
            let directory = try openAIExchangeDirectory()
            defer { close(directory) }
            let descriptor = openat(directory, file.id, O_RDONLY | O_NOFOLLOW)
            guard descriptor >= 0 else { throw StoreError.sharedFileNotFound }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, Self.validExchangeFile(info, size: file.size),
                  try Self.sha256(descriptor, checkpoint: { try preparation.check() }, progress: {
                      progress(file.size == 0 ? 1 : Double($0) / Double(file.size))
                  }) == file.sha256 else { throw StoreError.sharedFileUnavailable }
            var after = stat()
            guard fstat(descriptor, &after) == 0,
                  Self.exchangeFingerprint(info) == Self.exchangeFingerprint(after) else {
                throw StoreError.sharedFileUnavailable
            }
            return try preparation.commit {
                self.lock.lock()
                defer { self.lock.unlock() }
                self.aiPermissionLock.lock()
                defer { self.aiPermissionLock.unlock() }
                try self.validateAIPreparationLocked(preparation)
                guard let index = self.aiExchangeIndex.files.firstIndex(where: { $0.id == fileID }) else {
                    throw StoreError.sharedFileNotFound
                }
                file.aiReadAllowed = true
                self.aiExchangeIndex.files[index] = file
                do { try self.persistAIExchangeIndexLocked() }
                catch { self.aiExchangeIndex.files[index].aiReadAllowed = false; throw error }
                self.verifiedExchangeFiles[fileID] = Self.exchangeFingerprint(after)
                self.deniedAIIDs.remove(fileID)
                return file
            }
        }
        guard let sourceID else { throw StoreError.itemNotInInbox }
        let source = try exchangeSource(sourceID)
        return try registerAIExchangeFile(name: source.0.name, mimeType: source.0.mimeType,
                                          sourceURL: source.1, expectedSize: source.0.size,
                                          expectedSHA256: source.0.sha256, sourceItemID: sourceID,
                                          preparation: preparation, progress: progress)
    }

    // Phone revisions survive restart, including revokes received before an upload/grant.
    func applyPhoneAIRead(_ request: PhoneAIReadRequest,
                          progress: (Double) -> Void = { _ in }) throws -> PhoneAIReadStatus {
        guard UUID(uuidString: request.id) != nil, request.id == request.id.lowercased(),
              request.revision > 0,
              !request.allowed || (request.sourceID.flatMap(UUID.init(uuidString:)) != nil &&
                  request.sha256?.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil) else {
            throw StoreError.invalidExchangeInput
        }
        let preparation: AIReadPreparation
        let sourceID: String?
        let fileID: String?
        phoneIntentLock.lock()
        do {
            lock.lock()
            let previous = aiExchangeIndex.phoneIntents[request.id]
            lock.unlock()
            if let previous, request.revision < previous.revision {
                let status = phoneAIReadStatus(previous)
                phoneIntentLock.unlock()
                return status
            }
            if let previous, request.revision == previous.revision {
                guard request.allowed == previous.allowed,
                      !request.allowed || request.sourceID == previous.sourceID && request.sha256 == previous.sha256 else {
                    throw StoreError.invalidExchangeInput
                }
            }
            if let previous, request.revision == previous.revision, previous.locallyRevoked == true {
                let status = phoneAIReadStatus(previous)
                phoneIntentLock.unlock()
                return status
            }
            if request.allowed {
                if let bound = previous?.sourceID {
                    guard bound == request.sourceID, previous?.sha256 == request.sha256 else {
                        throw StoreError.invalidExchangeInput
                    }
                }
                let source = try exchangeSource(request.sourceID!).0
                guard source.sha256 == request.sha256 else { throw StoreError.checksumMismatch }
            }
            let committedID = phonePreparations.removeValue(forKey: request.id)?.cancel()
            var stored = request
            stored.locallyRevoked = nil
            if !request.allowed {
                stored.sourceID = previous?.sourceID
                stored.sha256 = previous?.sha256
            }
            sourceID = stored.sourceID
            lock.lock()
            // A local revoke may have completed while cancelling the previous preparation.
            if let latest = aiExchangeIndex.phoneIntents[request.id],
               latest.revision == request.revision, latest.locallyRevoked == true {
                lock.unlock()
                let status = phoneAIReadStatus(latest)
                phoneIntentLock.unlock()
                return status
            }
            fileID = aiExchangeIndex.files.first { $0.sourceItemID == sourceID && sourceID != nil }?.id
            preparation = makeAIReadPreparation(sourceID: sourceID, fileID: fileID)
            aiExchangeIndex.phoneIntents[request.id] = stored
            if !request.allowed {
                if let sourceID { invalidateAIReadPreparation(sourceID: sourceID) }
                for index in aiExchangeIndex.files.indices where
                    aiExchangeIndex.files[index].id == committedID ||
                    (sourceID != nil && aiExchangeIndex.files[index].sourceItemID == sourceID) {
                    let id = aiExchangeIndex.files[index].id
                    denyAIReadImmediately(id)
                    aiExchangeIndex.files[index].aiReadAllowed = false
                    verifiedExchangeFiles.removeValue(forKey: id)
                }
            }
            do { try persistAIExchangeIndexLocked() }
            catch {
                if request.allowed { aiExchangeIndex.phoneIntents[request.id] = previous }
                lock.unlock()
                throw error
            }
            lock.unlock()
            if request.allowed { phonePreparations[request.id] = preparation }
            phoneIntentLock.unlock()
        } catch {
            phoneIntentLock.unlock()
            throw error
        }
        guard request.allowed else { return phoneAIReadStatus(request) }
        defer {
            phoneIntentLock.lock()
            if phonePreparations[request.id] === preparation { phonePreparations.removeValue(forKey: request.id) }
            phoneIntentLock.unlock()
        }
        Thread.sleep(forTimeInterval: AIReadPreparation.delay)
        _ = try prepareAIRead(sourceID: sourceID, fileID: fileID, preparation: preparation, progress: progress)
        phoneIntentLock.lock()
        defer { phoneIntentLock.unlock() }
        lock.lock()
        let latest = aiExchangeIndex.phoneIntents[request.id]!
        lock.unlock()
        return phoneAIReadStatus(latest)
    }

    private func phoneAIReadStatus(_ request: PhoneAIReadRequest) -> PhoneAIReadStatus {
        lock.lock()
        defer { lock.unlock() }
        let allowed = request.allowed && request.locallyRevoked != true
        let ready = allowed && aiExchangeIndex.aiReadEnabled && aiExchangeIndex.files.contains {
            $0.sourceItemID == request.sourceID && $0.aiReadAllowed == true && !isAIDenied($0.id)
        }
        return PhoneAIReadStatus(id: request.id, revision: request.revision, allowed: allowed, ready: ready)
    }

    func receiveExchangeTextFile(filename: String, content: String, mimeType: String) throws -> AIExchangeFile {
        let data = Data(content.utf8)
        guard !filename.isEmpty, filename.utf8.count <= 1024, data.count <= 128 * 1024 else {
            throw StoreError.invalidExchangeInput
        }
        return try registerAIExchangeFile(name: filename, mimeType: mimeType, data: data)
    }

    func deleteAIExchangeFile(_ id: String) throws {
        denyAIReadImmediately(id)
        guard UUID(uuidString: id) != nil else { throw StoreError.sharedFileNotFound }
        lock.lock()
        defer { lock.unlock() }
        try deleteAIExchangeFileLocked(id.lowercased())
    }

    private func deleteAIExchangeFileLocked(_ id: String) throws {
        guard let index = aiExchangeIndex.files.firstIndex(where: { $0.id == id }) else {
            throw StoreError.sharedFileNotFound
        }
        denyAIReadImmediately(id)
        let file = aiExchangeIndex.files.remove(at: index)
        aiExchangeIndex.retiredIDs.insert(file.id)
        verifiedExchangeFiles.removeValue(forKey: file.id)
        var persistenceError: Error?
        do { try persistAIExchangeIndexLocked() }
        catch { persistenceError = error }
        let directory = try openAIExchangeDirectory()
        defer { close(directory) }
        if unlinkat(directory, file.id, 0) != 0, errno != ENOENT {
            throw StoreError.exchangeDeleteFailed
        }
        guard fsync(directory) == 0 else { throw StoreError.exchangeDeleteFailed }
        if let persistenceError { throw persistenceError }
    }

    func aiSharedFiles(offset: Int, limit: Int) throws -> SharedFilePage {
        lock.lock()
        defer { lock.unlock() }
        guard aiExchangeIndex.aiReadEnabled else { throw StoreError.aiExchangeDisabled }
        guard offset >= 0, limit > 0, limit <= 100 else { throw StoreError.invalidSharedFileRange }
        let files = aiExchangeIndex.files.filter { $0.aiReadAllowed == true && !isAIDenied($0.id) && Self.exchangeFileExists($0, directory: aiExchangeURL) }
        let selected = Array(files.dropFirst(offset).prefix(limit))
        let next = offset + selected.count < files.count ? offset + selected.count : nil
        return SharedFilePage(items: selected.map {
            SharedFileSummary(id: $0.id, name: $0.name, size: $0.size,
                              extension: URL(fileURLWithPath: $0.name).pathExtension.lowercased(),
                              receivedAt: $0.createdAt, state: "available")
        }, nextOffset: next, pendingImportCount: 0)
    }

    func aiSharedFileInfo(_ id: String) throws -> SharedFileInfo {
        guard !isAIDenied(id) else { throw StoreError.sharedFileNotFound }
        lock.lock()
        defer { lock.unlock() }
        guard aiExchangeIndex.aiReadEnabled else { throw StoreError.aiExchangeDisabled }
        guard let file = aiExchangeIndex.files.first(where: { $0.id == id.lowercased() && $0.aiReadAllowed == true }),
              Self.exchangeFileExists(file, directory: aiExchangeURL) else { throw StoreError.sharedFileNotFound }
        let extensionName = URL(fileURLWithPath: file.name).pathExtension.lowercased()
        let readable = Self.isTextFile(name: file.name, mimeType: file.mimeType)
        return SharedFileInfo(id: file.id, name: file.name, size: file.size, extension: extensionName,
                              mimeType: file.mimeType, sha256: file.sha256, receivedAt: file.createdAt,
                              state: "available", isReadable: readable,
                              reason: readable ? nil : "텍스트 파일 형식만 읽을 수 있습니다")
    }

    func readAIExchangeFile(_ id: String, offset: Int64, limit: Int) throws -> SharedFileChunk {
        let key = id.lowercased()
        try requireAIRead(key)
        lock.lock()
        let candidate = aiExchangeIndex.files.first { $0.id == key }
        lock.unlock()
        guard let file = candidate, Self.isTextFile(name: file.name, mimeType: file.mimeType) else {
            throw StoreError.sharedFileNotFound
        }
        func clearVerification() {
            lock.lock(); verifiedExchangeFiles.removeValue(forKey: file.id); lock.unlock()
        }
        guard offset >= 0, offset <= file.size, limit > 0, limit <= 32768 else {
            throw StoreError.invalidSharedFileRange
        }
        let directory = try openAIExchangeDirectory()
        defer { close(directory) }
        let descriptor = openat(directory, file.id, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw StoreError.sharedFileNotFound }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, Self.validExchangeFile(info, size: file.size) else {
            clearVerification()
            throw StoreError.sharedFileUnavailable
        }
        let fingerprint = Self.exchangeFingerprint(info)
        lock.lock()
        let cached = verifiedExchangeFiles[file.id]
        lock.unlock()
        if cached != fingerprint {
            guard try Self.sha256(descriptor, checkpoint: { try self.requireAIRead(file.id) }) == file.sha256 else {
                clearVerification()
                throw StoreError.sharedFileUnavailable
            }
            var afterHash = stat()
            guard fstat(descriptor, &afterHash) == 0,
                  Self.exchangeFingerprint(afterHash) == fingerprint else {
                clearVerification()
                throw StoreError.sharedFileUnavailable
            }
            lock.lock(); verifiedExchangeFiles[file.id] = fingerprint; lock.unlock()
        }
        let amount = min(limit, Int(file.size - offset))
        var bytes = [UInt8](repeating: 0, count: amount)
        let count = amount == 0 ? 0 : pread(descriptor, &bytes, amount, off_t(offset))
        guard count >= 0, offset == file.size || count > 0 else { throw StoreError.sharedFileUnavailable }
        var afterRead = stat()
        guard fstat(descriptor, &afterRead) == 0,
              Self.exchangeFingerprint(afterRead) == fingerprint else {
            clearVerification()
            throw StoreError.sharedFileUnavailable
        }
        let data = Data(bytes.prefix(max(0, count)))
        if let first = data.first, first & 0b1100_0000 == 0b1000_0000 { throw StoreError.invalidSharedFileRange }
        let (content, bytesRead) = try Self.decodeUTF8Chunk(data)
        guard offset == file.size || bytesRead > 0 else { throw StoreError.invalidSharedFileRange }
        let next = offset + Int64(bytesRead)
        try requireAIRead(file.id)
        return SharedFileChunk(id: file.id, content: content, offset: offset, nextOffset: next,
                               bytesRead: bytesRead, sizeBytes: file.size, hasMore: next < file.size)
    }

    private func registerAIExchangeFile(name: String, mimeType: String, data: Data? = nil,
                                        sourceURL: URL? = nil, expectedSize: Int64? = nil,
                                        expectedSHA256: String? = nil, sourceItemID: String? = nil,
                                        preparation: AIReadPreparation? = nil,
                                        progress: (Double) -> Void = { _ in }) throws -> AIExchangeFile {
        let directory = try openAIExchangeDirectory()
        defer { close(directory) }
        var id = UUID().uuidString.lowercased()
        let temporaryName = ".partial-\(UUID().uuidString.lowercased())"
        let target = openat(directory, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard target >= 0 else { throw StoreError.cannotCreateFile }
        var keepTemporary = true
        defer { if keepTemporary { _ = unlinkat(directory, temporaryName, 0) }; close(target) }

        var source: Int32 = -1
        defer { if source >= 0 { close(source) } }
        if let sourceURL {
            source = open(sourceURL.path, O_RDONLY | O_NOFOLLOW)
            guard source >= 0 else { throw StoreError.sharedFileUnavailable }
            var sourceInfo = stat()
            guard fstat(source, &sourceInfo) == 0,
                  sourceInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  sourceInfo.st_size >= 0, Int64(sourceInfo.st_size) <= Self.maximumItemSize else {
                throw StoreError.sharedFileUnavailable
            }
        }

        var digest = SHA256()
        var size: Int64 = 0
        if let data {
            try Self.writeAll(data, to: target)
            digest.update(data: data)
            size = Int64(data.count)
        } else {
            var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
            while true {
                try preparation?.check()
                let count = read(source, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw StoreError.sharedFileUnavailable }
                if count == 0 { break }
                size += Int64(count)
                guard size <= Self.maximumItemSize else { throw StoreError.itemTooLarge }
                let bytes = Data(buffer.prefix(count))
                try Self.writeAll(bytes, to: target)
                digest.update(data: bytes)
                if let expectedSize { progress(expectedSize == 0 ? 0.5 : 0.5 * Double(size) / Double(expectedSize)) }
            }
        }
        let checksum = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard size <= Self.maximumItemSize, expectedSize == nil || expectedSize == size,
              expectedSHA256 == nil || expectedSHA256 == checksum else { throw StoreError.checksumMismatch }
        guard fsync(target) == 0 else { throw StoreError.exchangeUnavailable }
        let verification = openat(directory, temporaryName, O_RDONLY | O_NOFOLLOW)
        guard verification >= 0 else { throw StoreError.exchangeUnavailable }
        defer { close(verification) }
        var stagedInfo = stat()
        guard fstat(verification, &stagedInfo) == 0,
              stagedInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              Int64(stagedInfo.st_size) == size,
              try Self.sha256(verification, checkpoint: { try preparation?.check() }, progress: {
                  progress(size == 0 ? 1 : 0.5 + 0.5 * Double($0) / Double(size))
              }) == checksum else { throw StoreError.checksumMismatch }
        func commit() throws -> AIExchangeFile {
            lock.lock()
            defer { lock.unlock() }
            aiPermissionLock.lock()
            defer { aiPermissionLock.unlock() }
            if let preparation { try validateAIPreparationLocked(preparation) }
            if let sourceItemID, !items.contains(where: { $0.id == sourceItemID }) {
                throw StoreError.itemNotInInbox
            }
            while aiExchangeIndex.retiredIDs.contains(id) || aiExchangeIndex.files.contains(where: { $0.id == id }) {
                id = UUID().uuidString.lowercased()
            }
            guard linkat(directory, temporaryName, directory, id, 0) == 0 else { throw StoreError.exchangeUnavailable }
            guard unlinkat(directory, temporaryName, 0) == 0 else {
                _ = unlinkat(directory, id, 0)
                throw StoreError.exchangeUnavailable
            }
            keepTemporary = false
            let file = AIExchangeFile(id: id, name: Self.safeExchangeName(name), mimeType: mimeType,
                                      size: size, sha256: checksum, createdAt: Date(),
                                      aiReadAllowed: preparation != nil, sourceItemID: sourceItemID)
            aiExchangeIndex.files.insert(file, at: 0)
            do { try persistAIExchangeIndexLocked() }
            catch {
                aiExchangeIndex.files.removeAll { $0.id == id }
                _ = unlinkat(directory, id, 0)
                throw StoreError.exchangeUnavailable
            }
            aiReadSources[id] = sourceItemID ?? id
            if preparation != nil, fstat(verification, &stagedInfo) == 0 {
                verifiedExchangeFiles[id] = Self.exchangeFingerprint(stagedInfo)
            }
            return file
        }
        return try preparation.map { try $0.commit(commit) } ?? commit()
    }

    private func persistAIExchangeIndexLocked() throws {
        let directory = try openAIExchangeDirectory()
        defer { close(directory) }
        let temporary = ".index-\(UUID().uuidString.lowercased())"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw StoreError.exchangeUnavailable }
        defer { close(descriptor); _ = unlinkat(directory, temporary, 0) }
        try Self.writeAll(JSONEncoder().encode(aiExchangeIndex), to: descriptor)
        guard fsync(descriptor) == 0,
              renameat(directory, temporary, directory, "index.json") == 0,
              fsync(directory) == 0 else {
            throw StoreError.exchangeUnavailable
        }
    }

    private func openAIExchangeDirectory() throws -> Int32 {
        let descriptor = open(aiExchangeURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw StoreError.exchangeUnavailable }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_mode & 0o777 == 0o700 else {
            close(descriptor)
            throw StoreError.exchangeUnavailable
        }
        return descriptor
    }

    private func pruneExchangeOrphans() {
        guard let directory = try? openAIExchangeDirectory() else { return }
        defer { close(directory) }
        let known = Set(aiExchangeIndex.files.map(\.id)).union(["index.json"])
        for name in (try? fileManager.contentsOfDirectory(atPath: aiExchangeURL.path)) ?? [] where !known.contains(name) {
            _ = unlinkat(directory, name, 0)
        }
    }

    private static func createPrivateDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        guard isRegularDirectoryWithoutSymlink(url), chmod(url.path, mode_t(0o700)) == 0 else {
            throw StoreError.exchangeUnavailable
        }
    }

    private static func exchangeFileExists(_ file: AIExchangeFile, directory: URL) -> Bool {
        guard UUID(uuidString: file.id) != nil, file.id == file.id.lowercased() else { return false }
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard dir >= 0 else { return false }
        defer { close(dir) }
        let descriptor = openat(dir, file.id, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var info = stat()
        return fstat(descriptor, &info) == 0 && validExchangeFile(info, size: file.size)
    }

    private static func validExchangeFile(_ info: stat, size: Int64) -> Bool {
        info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && info.st_mode & 0o777 == 0o600 &&
        info.st_nlink == 1 && info.st_uid == getuid() && Int64(info.st_size) == size
    }

    private static func exchangeFingerprint(_ info: stat) -> ExchangeFingerprint {
        ExchangeFingerprint(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size),
                            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
                            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                            changedSeconds: Int64(info.st_ctimespec.tv_sec),
                            changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }

    private static func isValidAIExchangeIndex(_ index: AIExchangeIndex) -> Bool {
        let ids = index.files.map(\.id)
        return Set(ids).count == ids.count && index.files.allSatisfy {
            UUID(uuidString: $0.id) != nil && $0.id == $0.id.lowercased() &&
            $0.size >= 0 && $0.size <= maximumItemSize &&
            $0.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil &&
            $0.name == safeExchangeName($0.name) && !$0.mimeType.isEmpty &&
            $0.mimeType.utf8.count <= 512 && !$0.mimeType.contains("\0") &&
            ($0.sourceItemID == nil || UUID(uuidString: $0.sourceItemID!) != nil)
        } && index.phoneIntents.allSatisfy { key, request in
            key == request.id && UUID(uuidString: key) != nil && key == key.lowercased() && request.revision > 0 &&
            (request.sourceID == nil || UUID(uuidString: request.sourceID!) != nil) &&
            (request.sha256 == nil || request.sha256!.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil) &&
            (!request.allowed || request.sourceID != nil && request.sha256 != nil)
        } && index.retiredIDs.allSatisfy {
            UUID(uuidString: $0) != nil && $0 == $0.lowercased() && !ids.contains($0)
        }
    }

    private static func sha256(_ descriptor: Int32, checkpoint: () throws -> Void = {},
                               progress: (Int64) -> Void = { _ in }) throws -> String {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else { throw StoreError.sharedFileUnavailable }
        var digest = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        var total: Int64 = 0
        while true {
            try checkpoint()
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw StoreError.sharedFileUnavailable }
            if count == 0 { break }
            digest.update(data: Data(buffer.prefix(count)))
            total += Int64(count)
            progress(total)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = write(descriptor, base.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw StoreError.exchangeUnavailable }
                offset += count
            }
        }
    }

    private func scheduleShareImports() {
        lock.lock()
        guard !isImportingShares else { lock.unlock(); return }
        isImportingShares = true
        lock.unlock()
        shareImportQueue.async { [weak self] in self?.importPendingShareBatches() }
    }

    private func importPendingShareBatches() {
        defer {
            lock.lock()
            isImportingShares = false
            lock.unlock()
        }
        guard let root = try? ShareHandoff.pendingRoot(),
              let batches = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        var changed = false
        for batch in batches {
            guard UUID(uuidString: batch.lastPathComponent) != nil, Self.isRegularDirectoryWithoutSymlink(batch) else { continue }
            let manifestURL = batch.appendingPathComponent("manifest.json")
            guard Self.isRegularFileWithoutSymlink(manifestURL),
                  let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(ShareHandoff.Manifest.self, from: data),
                  manifest.id == batch.lastPathComponent,
                  (1...ShareHandoff.maximumFiles).contains(manifest.files.count),
                  Set(manifest.files.map(\.id)).count == manifest.files.count else { continue }
            let files = batch.appendingPathComponent("files", isDirectory: true)
            guard Self.isRegularDirectoryWithoutSymlink(files) else { continue }
            var batchImported = true
            for entry in manifest.files {
                guard UUID(uuidString: entry.id) != nil, entry.size >= 0, entry.size <= Self.maximumItemSize,
                      entry.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                    batchImported = false
                    break
                }
                let source = files.appendingPathComponent(entry.id + ".data")
                guard Self.isRegularFileWithoutSymlink(source),
                      (try? Self.fileSize(source)) == entry.size,
                      (try? importReceivedFile(source, mimeType: ShareHandoff.mimeType(for: entry.name), name: entry.name,
                                               expectedSHA256: entry.sha256, receivedAt: manifest.createdAt)) != nil else {
                    batchImported = false
                    break
                }
                changed = true
            }
            if batchImported { try? fileManager.removeItem(at: batch) }
        }
        if changed { sharedItemsChangedHandler?() }
    }

    private func pendingShareImportCount() -> Int {
        guard let root = try? ShareHandoff.pendingRoot(),
              let batches = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return 0 }
        return batches.filter {
            UUID(uuidString: $0.lastPathComponent) != nil &&
            Self.isRegularFileWithoutSymlink($0.appendingPathComponent("manifest.json"))
        }.count
    }

    private func sharedFileURL(_ item: TransferItem) -> URL? {
        let url = storedURL(item)
        guard Self.isRegularFileWithoutSymlink(url), (try? Self.fileSize(url)) == item.size else { return nil }
        return url
    }

    private static func isTextFile(name: String, mimeType: String) -> Bool {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        return ["srt", "md", "markdown", "txt", "text", "json", "csv", "tsv", "xml", "yaml", "yml", "vtt", "log"].contains(ext)
            || mimeType.lowercased().hasPrefix("text/")
            || ["application/json", "application/xml", "application/yaml"].contains(mimeType.lowercased())
    }

    private static func decodeUTF8Chunk(_ bytes: Data) throws -> (String, Int) {
        let minimum = max(0, bytes.count - 3)
        for count in stride(from: bytes.count, through: minimum, by: -1) {
            if let text = String(data: bytes.prefix(count), encoding: .utf8), bytes.isEmpty || count > 0 { return (text, count) }
        }
        throw StoreError.invalidSharedFileEncoding
    }

    private static func isRegularFileWithoutSymlink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func isRegularDirectoryWithoutSymlink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    // Delivery receipts never remove a file retained in the Mac library.
    private func finishLibraryPhoneDeliveryLocked(_ id: String) throws -> Bool {
        if let index = items.firstIndex(where: { $0.id == id && $0.phoneDeliveryPending != nil }) {
            let previous = items[index]
            items[index].phoneDeliveryPending = false
            do { try persist() }
            catch { items[index] = previous; throw error }
            return true
        }
        if let index = aiExchangeIndex.files.firstIndex(where: { $0.id == id && $0.sourceItemID == nil }) {
            let previous = aiExchangeIndex.files[index]
            aiExchangeIndex.files[index].phoneDeliveryPending = false
            do { try persistAIExchangeIndexLocked() }
            catch { aiExchangeIndex.files[index] = previous; throw error }
            return true
        }
        return false
    }

    @discardableResult
    func acknowledge(_ id: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if try finishLibraryPhoneDeliveryLocked(id) { return true }
        guard let index = items.firstIndex(where: { $0.id == id && $0.origin == "mac" }) else { return true }
        let previous = items[index]
        items.remove(at: index)
        do {
            try persist()
        } catch {
            items.insert(previous, at: index)
            throw error
        }
        try? fileManager.removeItem(at: payloadURL(id))
        return true
    }

    private func payloadURL(_ id: String) -> URL {
        root.appendingPathComponent("payloads", isDirectory: true).appendingPathComponent(id)
    }

    private func uploadURL(_ id: String) -> URL {
        uploadsURL.appendingPathComponent(id + ".part")
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(items)
        try data.write(to: itemsURL, options: .atomic)
    }

    private func persistUploads() throws {
        let data = try JSONEncoder().encode(uploads)
        try data.write(to: uploadSessionsURL, options: .atomic)
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { return false }
            digest.update(data: data)
            return true
        }) {
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func synchronize(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else { throw StoreError.cannotReadSize }
        return size.int64Value
    }

    private static func safeName(_ name: String) -> String {
        let leaf = URL(fileURLWithPath: name).lastPathComponent
        let clean = String(leaf.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty || clean == "." || clean == ".." ? "Shared item" : String(clean.prefix(240))
    }

    private static func safeExchangeName(_ name: String) -> String {
        safeName(name.replacingOccurrences(of: "\\", with: "_"))
    }

    enum StoreError: LocalizedError {
        case cannotCreateFile
        case cannotReadSize
        case itemTooLarge
        case checksumMismatch
        case invalidUpload
        case invalidUploadRange
        case invalidSaveFolder
        case invalidTemporaryFolder
        case itemNotInInbox
        case eventCursorExpired
        case itemNotPending
        case sharedFileNotFound
        case sharedFileUnavailable
        case unsupportedSharedFile
        case invalidSharedFileRange
        case invalidSharedFileEncoding
        case invalidExchangeInput
        case aiExchangeDisabled
        case aiPreparationWaiting
        case exchangeUnavailable
        case exchangeDeleteFailed

        var errorDescription: String? {
            switch self {
            case .cannotCreateFile: return "임시 파일을 만들 수 없습니다"
            case .cannotReadSize: return "파일 크기를 확인할 수 없습니다"
            case .itemTooLarge: return "최대 전송 크기는 20 GiB입니다"
            case .checksumMismatch: return "전송 파일의 SHA-256 검증에 실패했습니다"
            case .invalidUpload: return "업로드 정보가 올바르지 않습니다"
            case .invalidUploadRange: return "업로드 이어받기 위치가 올바르지 않습니다"
            case .invalidSaveFolder: return "앱 데이터·임시 보관 폴더 밖의 저장 폴더를 선택하세요"
            case .invalidTemporaryFolder: return "접근 가능한 다른 임시 보관 폴더를 선택하세요. 연결된 드라이브와 폴더 권한을 확인하세요"
            case .itemNotInInbox: return "보관함에서 수신 대기 중인 파일이 아닙니다"
            case .eventCursorExpired: return "이벤트 커서가 만료되었습니다. 커서 없이 다시 조회하세요"
            case .itemNotPending: return "휴대전화 전송 대기 중인 파일이 아닙니다"
            case .sharedFileNotFound: return "ShareStack에서 공유 파일을 찾을 수 없습니다"
            case .sharedFileUnavailable: return "공유 파일을 안전하게 읽을 수 없습니다"
            case .unsupportedSharedFile: return "텍스트 파일 형식만 MCP 읽기를 지원합니다"
            case .invalidSharedFileRange: return "파일 읽기 offset 또는 limit이 올바르지 않습니다"
            case .invalidSharedFileEncoding: return "파일이 올바른 UTF-8 텍스트가 아닙니다"
            case .invalidExchangeInput: return "교환 파일 입력이 올바르지 않습니다"
            case .aiPreparationWaiting: return "AI 공개 유예 시간이 아직 끝나지 않았습니다"
            case .aiExchangeDisabled: return "AI Exchange 읽기가 꺼져 있습니다"
            case .exchangeUnavailable: return "AI Exchange를 안전하게 사용할 수 없습니다"
            case .exchangeDeleteFailed: return "AI Exchange 파일을 삭제하지 못했습니다"
            }
        }
    }
}

struct LibraryArrivalTracker {
    private var seen: Set<String>?

    mutating func update(_ ids: Set<String>) -> Bool {
        defer { seen = (seen ?? []).union(ids) }
        guard let seen else { return false }
        return !ids.subtracting(seen).isEmpty
    }
}
