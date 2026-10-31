import CryptoKit
import Darwin
import Foundation

struct WorkspaceRecord: Codable {
    enum Mode: String, Codable { case privateMode, readOnly, edit }
    let id: String
    let name: String
    var mode: Mode
    var files: [WorkspaceFile]
    var requests: [String: WorkspaceRequest]? = nil
    var directories: [String]? = nil
}

struct WorkspaceFile: Codable {
    let id: String
    let path: String
    var size: Int64
    var sha256: String
    var objectID: String? = nil
    var baselineHash: String? = nil
    var version: Int? = nil
    var created: Bool? = nil
}

struct WorkspaceRequest: Codable { let fingerprint: String; let file: WorkspaceFile }

final class WorkspaceStore {
    struct Summary { var included = 0; var excluded = 0; var bytes: Int64 = 0; var scanned = 0; var directories: [String] = [] }
    enum Failure: Error { case invalid, limit, io, denied, conflict }
    struct Entry: Encodable { let name: String; let relativePath: String; let kind: String; var id: String? = nil; var size: Int64? = nil }
    struct Page: Encodable { let items: [Entry]; let nextCursor: String? }
    struct Change: Encodable { let fileId: String; let relativePath: String; let version: Int; let diff: String; let diffOffset: Int; let hasMoreDiff: Bool }
    struct ChangePage: Encodable { let items: [Change]; let nextCursor: String? }
    struct Chunk: Encodable { let content: String; let nextOffset: Int; let hasMore: Bool }
    private static let lock = NSRecursiveLock()
    struct Session: Encodable { let id: String; let label: String; let createdAt: Date }
    struct SessionCredential: Encodable { let id: String; let credential: String }
    private struct SessionState { let session: Session; let credential: String }
    private static var sessions: [String: [String: SessionState]] = [:]
    private static var grants: [String: [String: String]] = [:]
    private static var revisions: [String: UInt64] = [:]
    private static var activeImports = Set<String>()
    private static var cleanedRoots = Set<String>()
    private var namespace: String { rootIdentity }
    private let rootIdentity: String
    private let enabled: () -> Bool
    private let rootFD: Int32
    private let root: URL
    private let manager = FileManager.default
    private let maxFiles = 10_000
    private let maxBytes: Int64 = 1024 * 1024 * 1024
    private let maxFile: Int64 = 100 * 1024 * 1024

    init(root: URL, enabled: @escaping () -> Bool = { true }) throws {
        self.enabled = enabled
        self.root = root
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var st = stat()
        guard lstat(root.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { throw Failure.io }
        rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw Failure.io }
        var opened = stat()
        guard fstat(rootFD, &opened) == 0, opened.st_dev == st.st_dev, opened.st_ino == st.st_ino, fchmod(rootFD, 0o700) == 0 else { close(rootFD); throw Failure.io }
        rootIdentity = String(opened.st_dev) + ":" + String(opened.st_ino)
        Self.lock.lock(); defer { Self.lock.unlock() }
        if !Self.cleanedRoots.contains(namespace) {
            for name in try names(rootFD) where name.hasPrefix(".partial-") && UUID(uuidString: String(name.dropFirst(9))) != nil && !Self.activeImports.contains(namespace + name) {
                try removeTree(rootFD, name: name)
            }
            Self.cleanedRoots.insert(namespace)
        }
    }

    deinit { close(rootFD) }

    func preview(_ source: URL) throws -> Summary {
        var summary = Summary(), files = [WorkspaceFile]()
        try walkSource(source, destination: nil, summary: &summary, files: &files)
        return summary
    }

    func importFolder(_ source: URL) throws -> WorkspaceRecord {
        guard try list().count < 32 else { throw Failure.limit }
        let id = UUID().uuidString.lowercased(), temporary = ".partial-" + UUID().uuidString.lowercased()
        Self.lock.lock()
        Self.activeImports.insert(namespace + temporary)
        let made = mkdirat(rootFD, temporary, 0o700)
        Self.lock.unlock()
        defer { Self.lock.lock(); Self.activeImports.remove(namespace + temporary); Self.lock.unlock() }
        guard made == 0 else { throw Failure.io }
        let fd = openat(rootFD, temporary, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { try? removeTree(rootFD, name: temporary); throw Failure.io }
        defer { close(fd) }
        do {
            guard mkdirat(fd, "files", 0o700) == 0, mkdirat(fd, "objects", 0o700) == 0 else { throw Failure.io }
            let destination = openat(fd, "files", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard destination >= 0 else { throw Failure.io }; defer { close(destination) }
            var summary = Summary(), files = [WorkspaceFile]()
            try walkSource(source, destination: destination, summary: &summary, files: &files)
            var record = WorkspaceRecord(id: id, name: source.lastPathComponent, mode: .privateMode, files: files)
            record.directories = summary.directories
            try atomicWrite(fd, name: "manifest.json", data: JSONEncoder().encode(record))
            Self.lock.lock(); defer { Self.lock.unlock() }
            guard try list().count < 32 else { throw Failure.limit }
            guard renameat(rootFD, temporary, rootFD, id) == 0 else { throw Failure.io }
            _ = fsync(rootFD)
            return record
        } catch { try? removeTree(rootFD, name: temporary); throw error }
    }

    private func names(_ fd: Int32) throws -> [String] {
        let copy = dup(fd)
        guard copy >= 0 else { throw Failure.io }
        guard let stream = fdopendir(copy) else { close(copy); throw Failure.io }
        defer { closedir(stream) }
        rewinddir(stream)
        var names = [String]()
        while true {
            errno = 0
            guard let entry = readdir(stream) else { guard errno == 0 else { throw Failure.io }; break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
            if name != "." && name != ".." { names.append(name) }
            guard names.count <= 20000 else { throw Failure.limit }
        }
        return names.sorted()
    }

    func list() throws -> [WorkspaceRecord] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var result = [WorkspaceRecord]()
        for name in try names(rootFD) where UUID(uuidString: name)?.uuidString.lowercased() == name {
            let fd = try directory(name); defer { close(fd) }
            let data = try readFile(fd, name: "manifest.json", maximum: 16 * 1024 * 1024)
            var record = try JSONDecoder().decode(WorkspaceRecord.self, from: data)
            guard record.id == name, record.files.count <= maxFiles, Set(record.files.map(\.id)).count == record.files.count,
                  Set(record.files.map(\.path)).count == record.files.count, (record.requests?.count ?? 0) <= 1000 else { throw Failure.io }
            for file in record.files {
                _ = try components(file.path)
                guard UUID(uuidString: file.id) != nil, file.size >= 0, file.size <= maxFile, file.sha256.count == 64,
                      file.objectID == nil || UUID(uuidString: file.objectID!)?.uuidString.lowercased() == file.objectID else { throw Failure.io }
            }
            for index in record.files.indices {
                if record.files[index].version == nil { record.files[index].version = 1 }
                if record.files[index].baselineHash == nil && record.files[index].created != true { record.files[index].baselineHash = record.files[index].sha256 }
            }
            result.append(record)
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func readFile(_ parent: Int32, name: String, maximum: Int) throws -> Data {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.io }; defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size >= 0, st.st_size <= maximum else { throw Failure.io }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count >= 0 else { throw Failure.io }
            if count == 0 { break }
            guard data.count <= maximum - count else { throw Failure.limit }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    func delete(_ id: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard UUID(uuidString: id)?.uuidString.lowercased() == id else { throw Failure.invalid }
        Self.revisions[namespace + id, default: 0] += 1
        Self.grants[namespace, default: [:]][id] = nil
        try removeTree(rootFD, name: id)
    }

    private func removeTree(_ parent: Int32, name: String) throws {
        var st = stat()
        guard fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.io }
        if st.st_mode & S_IFMT == S_IFDIR {
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Failure.io }; defer { close(fd) }
            for child in try names(fd) { try removeTree(fd, name: child) }
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw Failure.io }
        } else { guard unlinkat(parent, name, 0) == 0 else { throw Failure.io } }
    }

    func registerSession(label: String) throws -> SessionCredential {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var sessions = Self.sessions[namespace, default: [:]]
        sessions = sessions.filter { Date().timeIntervalSince($0.value.session.createdAt) < 24 * 3600 }
        guard sessions.count < 32 else { throw Failure.limit }
        let id = UUID().uuidString.lowercased(), credential = UUID().uuidString + UUID().uuidString
        sessions[id] = SessionState(session: Session(id: id, label: String(label.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }.prefix(80)), createdAt: Date()), credential: credential)
        Self.sessions[namespace] = sessions
        return SessionCredential(id: id, credential: credential)
    }

    func sessions() -> [Session] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return Self.sessions[namespace, default: [:]].values.map(\.session).filter { Date().timeIntervalSince($0.createdAt) < 24 * 3600 }.sorted { $0.createdAt > $1.createdAt }
    }

    func revokeSession(_ id: String) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.sessions[namespace, default: [:]][id] = nil
        for (workspace, session) in Self.grants[namespace, default: [:]] where session == id {
            Self.grants[namespace, default: [:]][workspace] = nil
            Self.revisions[namespace + workspace, default: 0] += 1
        }
    }

    func boundSession(_ id: String) -> String? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return Self.grants[namespace]?[id]
    }

    func setMode(_ id: String, _ mode: WorkspaceRecord.Mode, sessionID: String? = nil) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard var record = try list().first(where: { $0.id == id }) else { throw Failure.denied }
        if mode != .privateMode {
            guard let sessionID, let session = Self.sessions[namespace]?[sessionID], Date().timeIntervalSince(session.session.createdAt) < 24 * 3600 else { throw Failure.denied }
        }
        Self.revisions[namespace + id, default: 0] += 1
        Self.grants[namespace, default: [:]][id] = nil
        record.mode = mode
        try save(record)
        Self.grants[namespace, default: [:]][id] = mode == .privateMode ? nil : sessionID
    }

    func visibleWorkspaces(credential: String) throws -> [WorkspaceRecord] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard enabled() else { throw Failure.denied }
        return try list().filter { record in
            record.mode != .privateMode && authorized(record, credential)
        }
    }

    private func authorized(_ record: WorkspaceRecord, _ credential: String) -> Bool {
        guard record.mode != .privateMode, let id = Self.grants[namespace]?[record.id],
              let session = Self.sessions[namespace]?[id], Date().timeIntervalSince(session.session.createdAt) < 24 * 3600 else { return false }
        return session.credential == credential
    }

    private func require(_ id: String, credential: String, edit: Bool = false) throws -> WorkspaceRecord {
        guard enabled(), let record = try list().first(where: { $0.id == id }), authorized(record, credential),
              !edit || record.mode == .edit else { throw Failure.denied }
        return record
    }

    func entries(_ id: String, path: String, cursor: Int, limit: Int, credential: String) throws -> Page {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let record = try require(id, credential: credential)
        guard cursor >= 0, (1...100).contains(limit) else { throw Failure.invalid }
        if !path.isEmpty { _ = try components(path) }
        let prefix = path.isEmpty ? "" : path + "/"
        var entries: [String: Entry] = [:]
        for directory in record.directories ?? [] where directory.hasPrefix(prefix) {
            let remainder = String(directory.dropFirst(prefix.count))
            if let first = remainder.split(separator: "/").first { entries[String(first)] = Entry(name: String(first), relativePath: prefix + first, kind: "directory") }
        }
        for file in record.files where file.path.hasPrefix(prefix) {
            let remainder = String(file.path.dropFirst(prefix.count))
            let parts = remainder.split(separator: "/")
            guard let first = parts.first else { continue }
            if parts.count > 1 { entries[String(first)] = Entry(name: String(first), relativePath: prefix + first, kind: "directory") }
            else { entries[String(first)] = Entry(name: String(first), relativePath: file.path, kind: "file", id: file.id, size: file.size) }
        }
        let sorted = entries.keys.sorted().compactMap { entries[$0] }
        guard cursor <= sorted.count else { throw Failure.invalid }
        let page = Array(sorted.dropFirst(cursor).prefix(limit))
        return Page(items: page, nextCursor: cursor + page.count < sorted.count ? String(cursor + page.count) : nil)
    }

    func info(_ id: String, fileID: String, credential: String) throws -> WorkspaceFile {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let record = try require(id, credential: credential)
        guard let file = record.files.first(where: { $0.id == fileID }) else { throw Failure.denied }
        return file
    }

    func read(_ id: String, fileID: String, offset: Int, limit: Int, credential: String) throws -> Chunk {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard enabled(), offset >= 0, (4...32768).contains(limit),
              let record = try list().first(where: { $0.id == id && $0.mode != .privateMode }),
              authorized(record, credential),
              let file = record.files.first(where: { $0.id == fileID }) else { throw Failure.denied }
        guard Self.isText(file.path) else { throw Failure.denied }
        let data = try bytes(record.id, file: file)
        guard !data.contains(0), String(data: data, encoding: .utf8) != nil, offset <= data.count else { throw Failure.invalid }
        if offset < data.count && data[offset] & 0xc0 == 0x80 { throw Failure.invalid }
        var end = min(data.count, offset + limit)
        while end < data.count && data[end] & 0xc0 == 0x80 { end -= 1 }
        guard let text = String(data: data.subdata(in: offset..<end), encoding: .utf8) else { throw Failure.io }
        return Chunk(content: text, nextOffset: end, hasMore: end < data.count)
    }

    private static func isText(_ path: String) -> Bool {
        ["md", "srt", "txt", "json", "csv", "yaml", "yml", "xml", "vtt", "swift", "py", "js", "ts", "tsx", "jsx", "java", "kt", "html", "css", "sh"].contains((path as NSString).pathExtension.lowercased())
    }

    private func components(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.count <= 32, path.utf8.count <= 4096, path.rangeOfCharacter(from: .controlCharacters) == nil,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("%") && !$0.contains("\0") }) else { throw Failure.invalid }
        return parts
    }

    private func directory(_ id: String) throws -> Int32 {
        guard UUID(uuidString: id)?.uuidString.lowercased() == id else { throw Failure.denied }
        let result = openat(rootFD, id, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard result >= 0 else { throw Failure.io }
        return result
    }

    private func bytes(_ id: String, file: WorkspaceFile, baseline: Bool = false) throws -> Data {
        var fd = try directory(id)
        let path = (!baseline && file.objectID != nil) ? "objects/" + file.objectID! : "files/" + file.path
        for part in try components(path) {
            let next = openat(fd, part, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            close(fd); fd = next
            guard fd >= 0 else { throw Failure.io }
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size >= 0, st.st_size <= maxFile else { throw Failure.io }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            guard n >= 0 else { throw Failure.io }
            if n == 0 { break }
            guard data.count <= Int(maxFile) - n else { throw Failure.limit }
            data.append(contentsOf: buffer.prefix(n))
        }
        let expected = baseline ? (file.baselineHash ?? file.sha256) : file.sha256
        guard Self.hash(data) == expected else { throw Failure.conflict }
        return data
    }

    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func save(_ record: WorkspaceRecord) throws {
        let fd = try directory(record.id); defer { close(fd) }
        try atomicWrite(fd, name: "manifest.json", data: JSONEncoder().encode(record))
    }

    private func atomicWrite(_ fd: Int32, name: String, data: Data) throws {
        let temporary = ".partial-" + UUID().uuidString
        let output = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw Failure.io }
        defer { close(output); unlinkat(fd, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard n > 0 else { throw Failure.io }; offset += n
            }
        }
        guard fsync(output) == 0, renameat(fd, temporary, fd, name) == 0 else { throw Failure.io }
        _ = fsync(fd)
    }

    func guiChanges(_ id: String) throws -> ChangePage {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let sessionID = Self.grants[namespace]?[id], let credential = Self.sessions[namespace]?[sessionID]?.credential else { throw Failure.denied }
        return try changes(id, credential: credential)
    }

    func changes(_ id: String, cursor: String = "0:0", limit: Int = 20, credential: String) throws -> ChangePage {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let record = try require(id, credential: credential)
        let parts = cursor.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int(parts[0]), let offset = Int(parts[1]), start >= 0, offset >= 0, (1...100).contains(limit) else { throw Failure.invalid }
        let changed = record.files.filter { $0.created == true || $0.sha256 != ($0.baselineHash ?? $0.sha256) }.sorted { $0.path < $1.path }
        guard start <= changed.count, start != changed.count || offset == 0 else { throw Failure.invalid }
        var result = [Change](), index = start, position = offset, budget = 1024 * 1024
        while index < changed.count && result.count < limit && budget >= 4 {
            let file = changed[index]
            let old = file.created == true ? Data() : try bytes(id, file: file, baseline: true)
            let new = try bytes(id, file: file)
            let diff = Data(Self.diff(path: file.path, old: String(data: old, encoding: .utf8) ?? "", new: String(data: new, encoding: .utf8) ?? "").utf8)
            guard position <= diff.count, position == diff.count || diff[position] & 0xc0 != 0x80 else { throw Failure.invalid }
            var end = min(diff.count, position + min(262144, budget))
            while end < diff.count && diff[end] & 0xc0 == 0x80 { end -= 1 }
            result.append(Change(fileId: file.id, relativePath: file.path, version: file.version ?? 1, diff: String(decoding: diff[position..<end], as: UTF8.self), diffOffset: position, hasMoreDiff: end < diff.count))
            budget -= end - position
            if end < diff.count { position = end; break }
            index += 1; position = 0
        }
        return ChangePage(items: result, nextCursor: index < changed.count ? String(index) + ":" + String(position) : nil)
    }

    private static func lines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var result = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { result.removeLast() }
        return result
    }

    private static func diff(path: String, old: String, new: String) -> String {
        let before = lines(old), after = lines(new)
        var prefix = 0
        while prefix < min(before.count, after.count) && before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(before.count, after.count) - prefix && before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
        if old.hasSuffix("\n") != new.hasSuffix("\n") { suffix = 0; prefix = min(prefix, max(0, min(before.count, after.count) - 1)) }
        let start = max(0, prefix - 3), oldEnd = min(before.count, before.count - suffix + 3), newEnd = min(after.count, after.count - suffix + 3)
        var result = "--- a/" + path + "\n+++ b/" + path + "\n@@ -" + String(oldEnd == start ? start : start + 1) + "," + String(oldEnd - start) + " +" + String(newEnd == start ? start : start + 1) + "," + String(newEnd - start) + " @@\n"
        for index in start..<prefix { result += " " + before[index] + "\n" }
        for index in prefix..<(before.count - suffix) { result += "-" + before[index] + "\n"; if index == before.count - 1 && !old.hasSuffix("\n") { result += "\\ No newline at end of file\n" } }
        for index in prefix..<(after.count - suffix) { result += "+" + after[index] + "\n"; if index == after.count - 1 && !new.hasSuffix("\n") { result += "\\ No newline at end of file\n" } }
        for index in (before.count - suffix)..<oldEnd { result += " " + before[index] + "\n"; if index == before.count - 1 && !old.hasSuffix("\n") { result += "\\ No newline at end of file\n" } }
        return result
    }

    func create(_ id: String, path: String, content: String, requestKey: String, credential: String) throws -> WorkspaceFile {
        _ = try components(path)
        guard Self.isText(path), content.utf8.count <= 131072 else { throw Failure.invalid }
        return try mutate(id, fileID: nil, path: path, expectedHash: nil, input: content, requestKey: requestKey, credential: credential)
    }

    func patch(_ id: String, fileID: String, expectedHash: String, patch: String, requestKey: String, credential: String) throws -> WorkspaceFile {
        guard patch.utf8.count <= 131072 else { throw Failure.limit }
        return try mutate(id, fileID: fileID, path: nil, expectedHash: expectedHash, input: patch, requestKey: requestKey, credential: credential)
    }

    private func mutate(_ id: String, fileID: String?, path: String?, expectedHash: String?, input: String, requestKey: String, credential: String) throws -> WorkspaceFile {
        guard !requestKey.isEmpty, requestKey.utf8.count <= 128 else { throw Failure.invalid }
        let fingerprint = Self.hash(try JSONEncoder().encode([fileID ?? "", path ?? "", expectedHash ?? "", input]))
        Self.lock.lock()
        let record: WorkspaceRecord, old: WorkspaceFile?, original: Data, revision: UInt64
        do {
            record = try require(id, credential: credential, edit: true)
            if let request = record.requests?[requestKey] {
                guard request.fingerprint == fingerprint else { throw Failure.conflict }
                Self.lock.unlock(); return request.file
            }
            guard (record.requests?.count ?? 0) < 1000 else { throw Failure.limit }
            revision = Self.revisions[namespace + id, default: 0]
            if let fileID {
                guard let file = record.files.first(where: { $0.id == fileID }), Self.isText(file.path) else { throw Failure.denied }
                guard file.sha256 == expectedHash else { throw Failure.conflict }
                guard file.size <= 1024 * 1024 else { throw Failure.limit }
                old = file; original = try bytes(id, file: file)
            } else {
                guard let path, !(record.directories ?? []).contains(where: { $0 == path || $0.hasPrefix(path + "/") }), !record.files.contains(where: { $0.path == path || $0.path.hasPrefix(path + "/") || path.hasPrefix($0.path + "/") }), record.files.count < maxFiles else { throw Failure.conflict }
                old = nil; original = Data()
            }
            Self.lock.unlock()
        } catch { Self.lock.unlock(); throw error }
        let data: Data
        if let old {
            guard let text = String(data: original, encoding: .utf8) else { throw Failure.invalid }
            data = Data(try Self.applyPatch(input, to: text, path: old.path).utf8)
        } else { data = Data(input.utf8) }
        guard !data.contains(0), data.count <= 1024 * 1024 else { throw Failure.limit }
        Self.lock.lock(); defer { Self.lock.unlock() }
        var current = try require(id, credential: credential, edit: true)
        guard revision == Self.revisions[namespace + id, default: 0] else { throw Failure.denied }
        if let prior = current.requests?[requestKey] {
            guard prior.fingerprint == fingerprint else { throw Failure.conflict }; return prior.file
        }
        guard (current.requests?.count ?? 0) < 1000 else { throw Failure.limit }
        if let old { guard current.files.first(where: { $0.id == old.id })?.sha256 == old.sha256 else { throw Failure.conflict } }
        else { guard current.files.count < maxFiles, !(current.directories ?? []).contains(where: { $0 == path! || $0.hasPrefix(path! + "/") }), !current.files.contains(where: { $0.path == path! || $0.path.hasPrefix(path! + "/") || path!.hasPrefix($0.path + "/") }) else { throw Failure.conflict } }
        let total = current.files.reduce(Int64(0)) { $0 + $1.size } - (old?.size ?? 0) + Int64(data.count)
        guard total <= maxBytes else { throw Failure.limit }
        var file = old ?? WorkspaceFile(id: UUID().uuidString.lowercased(), path: path!, size: 0, sha256: "")
        file.baselineHash = old?.baselineHash ?? old?.sha256
        file.version = (old?.version ?? (old == nil ? 0 : 1)) + 1
        file.created = old?.created ?? (old == nil)
        file.size = Int64(data.count); file.sha256 = Self.hash(data); file.objectID = UUID().uuidString.lowercased()
        let dir = try directory(id); defer { close(dir) }
        guard mkdirat(dir, "objects", 0o700) == 0 || errno == EEXIST else { throw Failure.io }
        let objects = openat(dir, "objects", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard objects >= 0 else { throw Failure.io }; defer { close(objects) }
        try atomicWrite(objects, name: file.objectID!, data: data)
        if let index = current.files.firstIndex(where: { $0.id == file.id }) { current.files[index] = file } else { current.files.append(file) }
        current.requests = current.requests ?? [:]
        current.requests![requestKey] = WorkspaceRequest(fingerprint: fingerprint, file: file)
        do { try save(current) } catch { unlinkat(objects, file.objectID!, 0); throw error }
        if let previous = old?.objectID { unlinkat(objects, previous, 0) }
        return file
    }

    private static func applyPatch(_ patch: String, to text: String, path: String) throws -> String {
        // A single-file unified diff is parsed in-process; filenames never become filesystem arguments.
        var rows = patch.components(separatedBy: "\n")
        if rows.last == "" { rows.removeLast() }
        guard rows.count >= 3, rows[0] == "--- a/" + path, rows[1] == "+++ b/" + path else { throw Failure.invalid }
        let source = lines(text)
        var output: [String] = [], sourceIndex = 0, index = 2, outputNewline = text.hasSuffix("\n"), sawHunk = false
        let pattern = try NSRegularExpression(pattern: "^@@ -([0-9]+)(?:,([0-9]+))? \\+([0-9]+)(?:,([0-9]+))? @@(?: .*)?$")
        while index < rows.count {
            let header = rows[index] as NSString
            guard let match = pattern.firstMatch(in: rows[index], range: NSRange(location: 0, length: header.length)) else { throw Failure.invalid }
            func number(_ group: Int, default fallback: Int) throws -> Int { let range = match.range(at: group); if range.location == NSNotFound { return fallback }; guard let n = Int(header.substring(with: range)), n <= 100000000 else { throw Failure.invalid }; return n }
            let oldStart = try number(1, default: 0), oldCount = try number(2, default: 1), newStart = try number(3, default: 0), newCount = try number(4, default: 1)
            let start = oldCount == 0 ? oldStart : oldStart - 1
            guard start >= sourceIndex, start <= source.count else { throw Failure.conflict }
            output.append(contentsOf: source[sourceIndex..<start]); sourceIndex = start
            guard (newCount == 0 ? newStart : newStart - 1) == output.count else { throw Failure.invalid }
            index += 1; var removed = 0, added = 0; sawHunk = true
            var prior: Character? = nil
            while index < rows.count && !rows[index].hasPrefix("@@ ") {
                let row = rows[index]
                if row == "\\ No newline at end of file" {
                    guard let prior, index > 0 else { throw Failure.invalid }
                    if prior == "+" || prior == " " { outputNewline = false }
                    index += 1; continue
                }
                guard let kind = row.first, kind == " " || kind == "-" || kind == "+" else { throw Failure.invalid }
                let content = String(row.dropFirst())
                if kind != "+" {
                    guard sourceIndex < source.count, source[sourceIndex] == content else { throw Failure.conflict }
                    sourceIndex += 1; removed += 1
                }
                if kind != "-" { output.append(content); added += 1; outputNewline = true }
                prior = kind; index += 1
            }
            guard removed == oldCount, added == newCount else { throw Failure.invalid }
        }
        guard sawHunk else { throw Failure.invalid }
        if sourceIndex < source.count { output.append(contentsOf: source[sourceIndex...]); outputNewline = text.hasSuffix("\n") }
        return output.joined(separator: "\n") + (output.isEmpty || !outputNewline ? "" : "\n")
    }

    private func walkSource(_ source: URL, destination: Int32?, summary: inout Summary, files: inout [WorkspaceFile]) throws {
        guard let canonical = realpath(source.path, nil) else { throw Failure.invalid }
        let sourcePath = String(cString: canonical); free(canonical)
        guard let rootCanonical = realpath(root.path, nil) else { throw Failure.io }
        let rootPath = String(cString: rootCanonical); free(rootCanonical)
        guard rootPath != sourcePath, !rootPath.hasPrefix(sourcePath == "/" ? "/" : sourcePath + "/") else { throw Failure.invalid }
        guard !["app", "bundle", "framework"].contains(source.pathExtension.lowercased()) else { throw Failure.invalid }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.io }
        var selected = stat()
        guard lstat(source.path, &selected) == 0, selected.st_mode & S_IFMT == S_IFDIR else { close(fd); throw Failure.invalid }
        for part in sourcePath.split(separator: "/") {
            let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd); fd = next
            guard fd >= 0 else { throw Failure.invalid }
        }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == selected.st_dev, opened.st_ino == selected.st_ino else { throw Failure.invalid }
        try walk(fd, relative: "", destination: destination, depth: 0, summary: &summary, files: &files)
    }

    private func walk(_ directory: Int32, relative: String, destination: Int32?, depth: Int, summary: inout Summary, files: inout [WorkspaceFile]) throws {
        guard depth <= 32 else { throw Failure.limit }
        var sourceStat = stat(), rootStat = stat()
        guard fstat(directory, &sourceStat) == 0, fstat(rootFD, &rootStat) == 0 else { throw Failure.io }
        guard sourceStat.st_dev != rootStat.st_dev || sourceStat.st_ino != rootStat.st_ino else { throw Failure.invalid }
        for name in try names(directory) {
            summary.scanned += 1
            guard summary.scanned <= 20000 else { throw Failure.limit }
            if name == "." || name == ".." { continue }
            let lower = name.lowercased()
            if name.rangeOfCharacter(from: .controlCharacters) != nil || name.contains("%") || name.contains("\\") || name.hasPrefix(".") || ["node_modules", "build", "dist", "deriveddata", "__pycache__", "vendor", "cache", "caches", "target", "out", "coverage", "venv"].contains(lower) || ["app", "bundle", "framework", "alias", "key", "pem", "p12", "pfx", "crt", "cer", "der", "jks", "keystore", "p8", "mobileprovision"].contains((name as NSString).pathExtension.lowercased()) || ["token", "secret", "credential", "password", "private_key", "private-key", "id_rsa", "id_ed25519", "api_key", "api-key", "apikey", "service-account"].contains(where: lower.contains) {
                summary.excluded += 1; continue
            }
            var st = stat()
            guard fstatat(directory, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.io }
            let kind = st.st_mode & S_IFMT
            let path = relative.isEmpty ? name : relative + "/" + name
            if kind == S_IFDIR {
                let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw Failure.io }
                defer { close(child) }
                var opened = stat()
                guard fstat(child, &opened) == 0, opened.st_dev == st.st_dev, opened.st_ino == st.st_ino else { throw Failure.io }
                summary.directories.append(path)
                var target: Int32? = nil
                if let destination {
                    guard mkdirat(destination, name, 0o700) == 0 else { throw Failure.io }
                    let opened = openat(destination, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard opened >= 0 else { throw Failure.io }; target = opened
                }
                defer { if let target { close(target) } }
                try walk(child, relative: path, destination: target, depth: depth + 1, summary: &summary, files: &files)
            } else if kind == S_IFREG {
                guard st.st_size >= 0, st.st_size <= maxFile, summary.included < maxFiles, summary.bytes <= maxBytes - st.st_size else { throw Failure.limit }
                let input = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard input >= 0 else { throw Failure.io }
                defer { close(input) }
                var actual = stat()
                guard fstat(input, &actual) == 0, (actual.st_mode & S_IFMT) == S_IFREG, actual.st_dev == st.st_dev, actual.st_ino == st.st_ino, actual.st_size == st.st_size else { throw Failure.io }
                let finderInfo = fgetxattr(input, "com.apple.FinderInfo", nil, 0, 0, 0)
                let finderError = errno
                let resourceFork = fgetxattr(input, "com.apple.ResourceFork", nil, 0, 0, 0)
                let resourceError = errno
                if finderInfo >= 0 || resourceFork >= 0 { summary.excluded += 1; continue }
                guard finderError == ENOATTR, resourceError == ENOATTR else { throw Failure.io }
                summary.included += 1; summary.bytes += st.st_size
                if let destination {
                    var space = statvfs()
                    guard fstatvfs(destination, &space) == 0, UInt64(space.f_bavail) * UInt64(space.f_frsize) >= UInt64(st.st_size) else { throw Failure.limit }
                    let output = openat(destination, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    guard output >= 0 else { throw Failure.io }
                    defer { close(output) }
                    var hash = SHA256(), total: Int64 = 0, buffer = [UInt8](repeating: 0, count: 65536)
                    while true {
                        let n = Darwin.read(input, &buffer, buffer.count)
                        guard n >= 0 else { throw Failure.io }
                        if n == 0 { break }
                        total += Int64(n)
                        guard total <= st.st_size else { throw Failure.io }
                        hash.update(data: Data(buffer.prefix(n)))
                        var written = 0
                        while written < n {
                            let count = buffer.withUnsafeBytes { write(output, $0.baseAddress!.advanced(by: written), n - written) }
                            guard count > 0 else { throw Failure.io }; written += count
                        }
                    }
                    var after = stat()
                    guard total == st.st_size, fstat(input, &after) == 0, after.st_size == actual.st_size,
                          after.st_mtimespec.tv_sec == actual.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == actual.st_mtimespec.tv_nsec,
                          after.st_ctimespec.tv_sec == actual.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == actual.st_ctimespec.tv_nsec,
                          fsync(output) == 0 else { throw Failure.io }
                    let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                    files.append(WorkspaceFile(id: UUID().uuidString.lowercased(), path: path, size: total, sha256: digest, baselineHash: digest, version: 1))
                }
            } else { summary.excluded += 1 }
        }
    }
}
