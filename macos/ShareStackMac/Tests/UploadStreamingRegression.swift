import CryptoKit
import Foundation

@main
struct UploadStreamingRegression {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharestack-upload-stream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try TransferStore(rootDirectory: root.appendingPathComponent("Store"))
        let content = Data("resume this upload safely".utf8)
        let digest = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        let session = UploadSession(id: digest, name: "resume.txt", mimeType: "text/plain",
                                    size: Int64(content.count), sha256: digest)
        let initial = try store.beginUpload(session)
        assert(initial.offset == 0 && !initial.complete)

        let interruptedRange = UploadRange(start: 0, end: 7, total: Int64(content.count))
        let first = try store.beginUploadChunk(digest, range: interruptedRange)
        try first.append(Data(content.prefix(3)))
        do {
            _ = try store.beginUploadChunk(digest, range: interruptedRange)
            assertionFailure("A second writer started for the same upload ID")
        } catch TransferStore.StoreError.invalidUploadRange { }
        first.cancel()

        let resumed = try store.beginUpload(session)
        assert(resumed.offset == 3 && !resumed.complete)
        let rest = UploadRange(start: resumed.offset, end: Int64(content.count - 1), total: Int64(content.count))
        let second = try store.beginUploadChunk(digest, range: rest)
        try second.append(Data(content.dropFirst(Int(resumed.offset))))
        let completedChunk = try second.finish()
        assert(completedChunk.offset == Int64(content.count))

        let item = try store.finishUpload(digest)
        assert(item.sha256 == digest)
        guard let file = store.fileURL(for: item.id) else { fatalError("Completed upload has no file") }
        let stored = try Data(contentsOf: file)
        assert(stored == content)
        print("PASS: one writer per upload ID, partial-chunk resume, final hash and stored bytes")
    }
}
