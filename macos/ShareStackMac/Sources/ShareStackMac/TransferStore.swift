import CryptoKit
import Foundation

struct TransferItem: Codable, Identifiable {
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
}

struct ReceiptSettings: Codable {
    enum Mode: String, Codable {
        case inbox
        case automatic
    }

    var mode: Mode = .inbox
    var folderPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads/Share Stack", isDirectory: true).path
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

// Mutable state is protected by lock; file paths and FileManager are shared safely across queues.
final class TransferStore: @unchecked Sendable {
    static let maximumItemSize: Int64 = 20 * 1024 * 1024 * 1024

    private let fileManager = FileManager.default
    private let root: URL
    private let itemsURL: URL
    private let temporaryURL: URL
    private let uploadsURL: URL
    private let uploadSessionsURL: URL
    private let inboxURL: URL
    private let settingsURL: URL
    private var items: [TransferItem]
    private var uploads: [String: UploadSession]
    private var settings: ReceiptSettings
    private let eventStreamID = UUID().uuidString.lowercased()
    private var events: [TransferEvent] = []
    private var eventSequence = 0
    private let lock = NSLock()

    init() throws {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        root = support.appendingPathComponent("ShareStackMac", isDirectory: true)
        itemsURL = root.appendingPathComponent("items.json")
        temporaryURL = root.appendingPathComponent("temporary", isDirectory: true)
        uploadsURL = root.appendingPathComponent("uploads", isDirectory: true)
        uploadSessionsURL = root.appendingPathComponent("uploads.json")
        inboxURL = root.appendingPathComponent("inbox-temporary", isDirectory: true)
        settingsURL = root.appendingPathComponent("receipt-settings.json")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: uploadsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: inboxURL, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let payloadDirectory = root.appendingPathComponent("payloads", isDirectory: true)
        try fileManager.createDirectory(at: payloadDirectory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: itemsURL.path) {
            items = try JSONDecoder().decode([TransferItem].self, from: Data(contentsOf: itemsURL))
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
        for file in (try? fileManager.contentsOfDirectory(at: temporaryURL, includingPropertiesForKeys: nil)) ?? [] {
            try? fileManager.removeItem(at: file)
        }
    }

    func makeTemporaryFile() throws -> URL {
        let url = temporaryURL.appendingPathComponent(UUID().uuidString.lowercased())
        guard fileManager.createFile(atPath: url.path, contents: nil) else {
            throw StoreError.cannotCreateFile
        }
        return url
    }

    func saveReceivedFile(_ temporaryFile: URL, name: String, mimeType: String, expectedSHA256: String) throws -> TransferItem {
        lock.lock()
        defer { lock.unlock() }
        return try saveReceivedFileLocked(temporaryFile, name: name, mimeType: mimeType, expectedSHA256: expectedSHA256)
    }

    func beginUpload(_ session: UploadSession) throws -> UploadStatus {
        lock.lock()
        defer { lock.unlock() }
        guard session.id == session.sha256,
              session.id.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              session.size >= 0, session.size <= Self.maximumItemSize,
              !session.name.isEmpty, !session.mimeType.isEmpty else { throw StoreError.invalidUpload }
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

    func appendUploadChunk(_ id: String, range: UploadRange, data: Data) throws -> UploadStatus {
        lock.lock()
        defer { lock.unlock() }
        guard let session = uploads[id], !data.isEmpty,
              range.total == session.size, range.start >= 0, range.start <= session.size,
              range.end >= range.start, range.end < session.size,
              range.length == Int64(data.count) else { throw StoreError.invalidUploadRange }
        let partial = uploadURL(id)
        guard try Self.fileSize(partial) == range.start else { throw StoreError.invalidUploadRange }
        let handle = try FileHandle(forWritingTo: partial)
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        return UploadStatus(id: id, offset: range.start + Int64(data.count), complete: false)
    }

    func finishUpload(_ id: String) throws -> TransferItem {
        lock.lock()
        defer { lock.unlock() }
        if let existing = receivedItemLocked(sha256: id) {
            try removeUploadLocked(id)
            return existing
        }
        guard let session = uploads[id], try Self.fileSize(uploadURL(id)) == session.size else {
            throw StoreError.invalidUploadRange
        }
        let item = try saveReceivedFileLocked(uploadURL(id), name: session.name, mimeType: session.mimeType, expectedSHA256: session.sha256)
        try removeUploadLocked(id)
        return item
    }

    private func saveReceivedFileLocked(_ temporaryFile: URL, name: String, mimeType: String, expectedSHA256: String) throws -> TransferItem {
        guard expectedSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            try? fileManager.removeItem(at: temporaryFile)
            throw StoreError.checksumMismatch
        }
        let size = try Self.fileSize(temporaryFile)
        guard size <= Self.maximumItemSize else {
            try? fileManager.removeItem(at: temporaryFile)
            throw StoreError.itemTooLarge
        }
        let sha256 = try Self.sha256(temporaryFile)
        guard sha256 == expectedSHA256 else {
            try? fileManager.removeItem(at: temporaryFile)
            throw StoreError.checksumMismatch
        }
        if let duplicate = receivedItemLocked(sha256: sha256) {
            try? fileManager.removeItem(at: temporaryFile)
            return duplicate
        }
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
            createdAt: Date()
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
        return settings
    }

    func updateReceiptSettings(_ value: ReceiptSettings) throws {
        lock.lock()
        defer { lock.unlock() }
        let folder = URL(fileURLWithPath: value.folderPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let dataPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard folder.path != dataPath, !folder.path.hasPrefix(dataPath + "/") else {
            throw StoreError.invalidSaveFolder
        }
        var updated = value
        updated.folderPath = folder.path
        try JSONEncoder().encode(updated).write(to: settingsURL, options: .atomic)
        settings = updated
    }

    func inboxItems() -> [TransferItem] {
        lock.lock()
        defer { lock.unlock() }
        return items.filter { Self.isAwaitingAcceptance($0) }
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
        items[index].state = "saved"
        items[index].savedPath = destination.path
        items[index].saveError = nil
        do {
            try persist()
        } catch {
            items[index] = previous
            try fileManager.moveItem(at: destination, to: source)
            throw error
        }
        recordEventLocked("file.saved", itemID: id)
        return items[index]
    }

    func cancelReceivedItem(_ id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let index = items.firstIndex(where: { $0.id == id && Self.isAwaitingAcceptance($0) }) else {
            throw StoreError.itemNotInInbox
        }
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
        recordEventLocked("file.cancelled", itemID: id)
    }

    private static func isAwaitingAcceptance(_ item: TransferItem) -> Bool {
        item.origin == "galaxy" && (item.state == "awaitingAcceptance" || item.state == "received")
    }

    private func receivedItemLocked(sha256: String) -> TransferItem? {
        items.first { $0.origin == "galaxy" && $0.sha256 == sha256 && fileManager.fileExists(atPath: storedURL($0).path) }
    }

    private func storedURL(_ item: TransferItem) -> URL {
        if let path = item.savedPath { return URL(fileURLWithPath: path) }
        if item.state == "awaitingAcceptance" { return inboxURL.appendingPathComponent(item.id) }
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
        lock.lock()
        defer { lock.unlock() }
        let size = try Self.fileSize(temporaryFile)
        guard size <= Self.maximumItemSize else {
            try? fileManager.removeItem(at: temporaryFile)
            throw StoreError.itemTooLarge
        }
        let sha256 = try Self.sha256(temporaryFile)
        if let expectedSHA256, sha256 != expectedSHA256 { throw StoreError.checksumMismatch }
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

    func pendingForGalaxy() -> [TransferItem] {
        lock.lock()
        defer { lock.unlock() }
        return items.filter { $0.origin == "mac" && $0.state == "pending" }
    }

    func recentItems(limit: Int = 8, offset: Int = 0) -> [TransferItem] {
        lock.lock()
        defer { lock.unlock() }
        return Array(items.dropFirst(max(0, offset)).prefix(max(0, limit)))
    }

    func fileURL(for id: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        let url = storedURL(item)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func item(for id: String) -> TransferItem? {
        lock.lock()
        defer { lock.unlock() }
        return items.first { $0.id == id }
    }

    @discardableResult
    func acknowledge(_ id: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let index = items.firstIndex(where: { $0.id == id && $0.origin == "mac" }) else { return false }
        guard items[index].state != "delivered" else { return true }
        let previous = items[index]
        items[index].state = "delivered"
        do {
            try persist()
        } catch {
            items[index] = previous
            throw error
        }
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
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
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

    enum StoreError: LocalizedError {
        case cannotCreateFile
        case cannotReadSize
        case itemTooLarge
        case checksumMismatch
        case invalidUpload
        case invalidUploadRange
        case invalidSaveFolder
        case itemNotInInbox
        case eventCursorExpired

        var errorDescription: String? {
            switch self {
            case .cannotCreateFile: return "임시 파일을 만들 수 없습니다"
            case .cannotReadSize: return "파일 크기를 확인할 수 없습니다"
            case .itemTooLarge: return "최대 전송 크기는 20 GiB입니다"
            case .checksumMismatch: return "전송 파일의 SHA-256 검증에 실패했습니다"
            case .invalidUpload: return "업로드 정보가 올바르지 않습니다"
            case .invalidUploadRange: return "업로드 이어받기 위치가 올바르지 않습니다"
            case .invalidSaveFolder: return "앱 데이터 폴더 밖의 저장 폴더를 선택하세요"
            case .itemNotInInbox: return "보관함에서 수신 대기 중인 파일이 아닙니다"
            case .eventCursorExpired: return "이벤트 커서가 만료되었습니다. 커서 없이 다시 조회하세요"
            }
        }
    }
}
