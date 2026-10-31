import CryptoKit
import Darwin
import Foundation

private final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var ids = [String]()
    func add(_ id: String) { lock.lock(); ids.append(id); lock.unlock() }
    func all() -> [String] { lock.lock(); defer { lock.unlock() }; return ids }
}
@main struct WorkspaceRegression {
    static func check(_ value: @autoclosure () throws -> Bool) throws { let actual = try value(); precondition(actual) }
    static func denied(_ body: () throws -> Void) throws {
        do { try body(); fatalError("permission bypass") } catch WorkspaceStore.Failure.denied {}
    }
    static func conflict(_ body: () throws -> Void) throws {
        do { try body(); fatalError("conflict ignored") } catch WorkspaceStore.Failure.conflict {}
    }
    static func main() throws {
        let fm = FileManager.default
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "restart" {
            let reopened = try WorkspaceStore(root: URL(fileURLWithPath: CommandLine.arguments[2]))
            let persisted = try reopened.list()
            precondition(persisted.count == 1 && persisted[0].mode == .readOnly)
            try check(reopened.visibleWorkspaces(credential: CommandLine.arguments[3]).isEmpty)
            print("PASS process restart keeps mode and invalidates old session approvals")
            return
        }
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let source = base.appendingPathComponent("source")
        try fm.createDirectory(at: source.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent("empty.txt"), withIntermediateDirectories: true)
        let original = Data("hello한😀日本語\n".utf8)
        try original.write(to: source.appendingPathComponent("sub/a.txt"))
        try Data("secret".utf8).write(to: source.appendingPathComponent(".env"))
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "/etc/passwd")
        let root = base.appendingPathComponent("store")
        let store = try WorkspaceStore(root: root)
        let preview = try store.preview(source)
        precondition(preview.included == 1 && preview.excluded == 2)
        do { _ = try store.preview(base); fatalError("recursive import") } catch WorkspaceStore.Failure.invalid {}
        let workspace = try store.importFolder(source), id = workspace.id, fid = workspace.files[0].id
        let first = try store.registerSession(label: "First"), other = try store.registerSession(label: "Other")
        try check(store.visibleWorkspaces(credential: first.credential).isEmpty)
        try denied { _ = try store.read(id, fileID: fid, offset: 0, limit: 4, credential: first.credential) }
        try store.setMode(id, .readOnly, sessionID: first.id)
        try check(store.visibleWorkspaces(credential: first.credential).count == 1)
        try check(store.visibleWorkspaces(credential: other.credential).isEmpty)
        try denied { _ = try store.info(id, fileID: fid, credential: other.credential) }
        let page = try store.entries(id, path: "sub", cursor: 0, limit: 1, credential: first.credential)
        precondition(page.items[0].id! == fid)
        var offset = 0, restored = Data()
        repeat {
            let part = try store.read(id, fileID: fid, offset: offset, limit: 4, credential: first.credential)
            restored.append(contentsOf: part.content.utf8); offset = part.nextOffset
        } while offset < original.count
        precondition(restored == original)
        try denied { _ = try store.create(id, path: "new.txt", content: "new", requestKey: "read-create", credential: first.credential) }
        let hash = workspace.files[0].sha256
        let patch = "--- a/sub/a.txt\n+++ b/sub/a.txt\n@@ -1 +1 @@\n-hello한😀日本語\n+edited\n"
        try denied { _ = try store.patch(id, fileID: fid, expectedHash: hash, patch: patch, requestKey: "read-patch", credential: first.credential) }
        try store.setMode(id, .edit, sessionID: first.id)
        let edited = try store.patch(id, fileID: fid, expectedHash: hash, patch: patch, requestKey: "edit", credential: first.credential)
        try check(store.read(id, fileID: fid, offset: 0, limit: 32, credential: first.credential).content == "edited\n")
        try check(store.patch(id, fileID: fid, expectedHash: hash, patch: patch, requestKey: "edit", credential: first.credential).sha256 == edited.sha256)
        try conflict { _ = try store.patch(id, fileID: fid, expectedHash: hash, patch: patch, requestKey: "stale", credential: first.credential) }
        try conflict { _ = try store.create(id, path: "other.txt", content: "different", requestKey: "edit", credential: first.credential) }
        try conflict { _ = try store.create(id, path: "empty.txt", content: "collision", requestKey: "directory-collision", credential: first.credential) }
        let created = try store.create(id, path: "new/deep.txt", content: "no newline", requestKey: "new", credential: first.credential)
        try check(store.create(id, path: "new/deep.txt", content: "no newline", requestKey: "new", credential: first.credential).id == created.id)
        try check(store.changes(id, credential: first.credential).items.count == 2)
        let duplicateResults = Results(), duplicateGroup = DispatchGroup()
        for _ in 0..<16 {
            duplicateGroup.enter()
            DispatchQueue.global().async {
                defer { duplicateGroup.leave() }
                do { duplicateResults.add(try store.create(id, path: "parallel.txt", content: "parallel", requestKey: "parallel", credential: first.credential).id) }
                catch { duplicateResults.add("ERROR") }
            }
        }
        duplicateGroup.wait()
        precondition(duplicateResults.all().count == 16 && Set(duplicateResults.all()).count == 1 && !duplicateResults.all().contains("ERROR"))
        let largeContent = String(repeating: "a\n", count: 60000)
        var largeFile = try store.create(id, path: "aaa-large.txt", content: largeContent, requestKey: "large-create", credential: first.credential)
        for n in 0..<2 {
            let oldLines = 60000 + 40000 * n
            let largePatch = "--- a/aaa-large.txt\n+++ b/aaa-large.txt\n@@ -" + String(oldLines) + ",0 +" + String(oldLines + 1) + ",40000 @@\n" + String(repeating: "+a\n", count: 40000)
            largeFile = try store.patch(id, fileID: largeFile.id, expectedHash: largeFile.sha256, patch: largePatch, requestKey: "large-patch" + String(n), credential: first.credential)
        }
        let firstDiff = try store.changes(id, limit: 1, credential: first.credential)
        precondition(firstDiff.items.count == 1 && firstDiff.items[0].hasMoreDiff && firstDiff.items[0].diff.utf8.count <= 262144 && firstDiff.nextCursor != nil)
        let secondDiff = try store.changes(id, cursor: firstDiff.nextCursor!, limit: 1, credential: first.credential)
        precondition(secondDiff.items[0].fileId == firstDiff.items[0].fileId && secondDiff.items[0].diffOffset == firstDiff.items[0].diff.utf8.count && !secondDiff.items[0].hasMoreDiff)
        let combinedDiff = firstDiff.items[0].diff + secondDiff.items[0].diff
        precondition(combinedDiff.components(separatedBy: "+a\n").count - 1 == 140000)
        for path in ["../escape.txt", "/absolute.txt", "a/%2e%2e/b.txt", "a\\b.txt", "a//b.txt"] {
            do { _ = try store.create(id, path: path, content: "x", requestKey: path, credential: first.credential); fatalError("escape allowed") }
            catch WorkspaceStore.Failure.invalid {}
        }
        let mutationGroup = DispatchGroup(), gate = DispatchSemaphore(value: 0)
        for n in 0..<16 {
            mutationGroup.enter()
            DispatchQueue.global().async {
                defer { mutationGroup.leave() }; gate.wait()
                _ = try? store.create(id, path: "race" + String(n) + ".txt", content: String(repeating: "x", count: 100000), requestKey: "race" + String(n), credential: first.credential)
            }
        }
        for _ in 0..<16 { gate.signal() }
        try store.setMode(id, .readOnly, sessionID: first.id)
        let countAtRevocation = try store.entries(id, path: "", cursor: 0, limit: 100, credential: first.credential).items.count
        mutationGroup.wait()
        try check(store.entries(id, path: "", cursor: 0, limit: 100, credential: first.credential).items.count == countAtRevocation)
        try denied { _ = try store.create(id, path: "blocked.txt", content: "x", requestKey: "blocked", credential: first.credential) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["restart", root.path, first.credential]
        try process.run(); process.waitUntilExit(); precondition(process.terminationStatus == 0)
        try store.setMode(id, .privateMode)
        try denied { _ = try store.read(id, fileID: fid, offset: 0, limit: 4, credential: first.credential) }
        let restarted = try WorkspaceStore(root: root)
        try check(restarted.visibleWorkspaces(credential: first.credential).isEmpty)
        try check(Data(contentsOf: source.appendingPathComponent("sub/a.txt")) == original)
        let mode = try fm.attributesOfItem(atPath: root.appendingPathComponent(id).appendingPathComponent("manifest.json").path)[.posixPermissions] as! NSNumber
        precondition(mode.intValue == 0o600)
        // A swapped parent must not make a new store inherit the approved root's grants.
        try store.setMode(id, .readOnly, sessionID: first.id)
        let moved = base.appendingPathComponent("moved-store")
        try fm.moveItem(at: root, to: moved)
        let replacement = try WorkspaceStore(root: root)
        try check(replacement.sessions().isEmpty)
        try check(store.read(id, fileID: fid, offset: 0, limit: 32, credential: first.credential).content == "edited\n")
        try store.delete(id)
        try check(Data(contentsOf: source.appendingPathComponent("sub/a.txt")) == original)
        let oversized = source.appendingPathComponent("oversized.txt")
        let large = open(oversized.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        precondition(large >= 0 && ftruncate(large, 100 * 1024 * 1024 + 1) == 0); close(large)
        do { _ = try replacement.importFolder(source); fatalError("size limit ignored") } catch WorkspaceStore.Failure.limit {}
        try check(fm.contentsOfDirectory(atPath: root.path).isEmpty)
        try fm.removeItem(at: oversized)
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("directory-link").path, withDestinationPath: source.path)
        let fifo = source.appendingPathComponent("fifo"); precondition(mkfifo(fifo.path, 0o600) == 0)
        let safety = try replacement.preview(source)
        precondition(safety.excluded >= 4)
        let outside = base.appendingPathComponent("external.txt")
        try Data("external".utf8).write(to: outside)
        try fm.linkItem(at: outside, to: source.appendingPathComponent("hard.txt"))
        let independent = try replacement.importFolder(source)
        let hardCopy = root.appendingPathComponent(independent.id + "/files/hard.txt")
        var copiedStat = stat(), outsideStat = stat()
        precondition(lstat(hardCopy.path, &copiedStat) == 0 && lstat(outside.path, &outsideStat) == 0)
        precondition(copiedStat.st_ino != outsideStat.st_ino && copiedStat.st_nlink == 1)
        try replacement.delete(independent.id)
        let capRoot = base.appendingPathComponent("cap-store"), capStore = try WorkspaceStore(root: capRoot)
        var capRecord = try capStore.importFolder(source)
        let capSession = try capStore.registerSession(label: "caps")
        try capStore.setMode(capRecord.id, .edit, sessionID: capSession.id)
        capRecord.mode = .edit
        let template = capRecord.files[0]
        capRecord.files = (0..<9999).map { WorkspaceFile(id: UUID().uuidString.lowercased(), path: "fixture" + String($0) + ".txt", size: 0, sha256: template.sha256) }
        capRecord.requests = Dictionary(uniqueKeysWithValues: (0..<999).map { ("old" + String($0), WorkspaceRequest(fingerprint: "fixture", file: template)) })
        try JSONEncoder().encode(capRecord).write(to: capRoot.appendingPathComponent(capRecord.id + "/manifest.json"), options: .atomic)
        let capID = capRecord.id
        let capResults = Results(), capGroup = DispatchGroup()
        for n in 0..<4 {
            capGroup.enter()
            DispatchQueue.global().async {
                defer { capGroup.leave() }
                do { capResults.add(try capStore.create(capID, path: "cap" + String(n) + ".txt", content: "x", requestKey: "cap" + String(n), credential: capSession.credential).id) }
                catch { capResults.add("DENIED") }
            }
        }
        capGroup.wait()
        precondition(capResults.all().filter { $0 != "DENIED" }.count == 1)
        let capped = try capStore.list()[0]
        precondition(capped.files.count == 10000 && capped.requests!.count == 1000)
        print("PASS bounded diff pages reconstruct, empty-directory collision denied, concurrent file/request caps")
        print("PASS concurrent replay and permission downgrade fence; hardlinks become independent files")
        print("PASS source aliases/special files excluded, copy limits roll back, root replacement and restart isolation")
        print("PASS private/session isolation, UTF8 paging, read-only denial, CAS, replay, edits, diff, revoke, traversal, original preservation")
    }
}
