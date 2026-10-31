import Foundation

@main
struct PhoneDeliveryRegression {
    static func check(_ condition: @autoclosure () throws -> Bool) throws {
        let value = try condition(); precondition(value)
    }

    static func main() throws {
        let range = UploadRange.parse("bytes=8-12", fileSize: 20)
        precondition(range?.start == 8 && range?.end == 12 && range?.total == 20, "Android download Range header must be accepted")
        assert(UploadRange.parse("bytes=0-20", fileSize: 20) == nil)
        assert(UploadRange.parse("bytes=9-2", fileSize: 20) == nil)
        assert(UploadRange.parse("bytes=0-1,4-5", fileSize: 20) == nil)
        assert(UploadRange.parse("bytes=0-1") == nil)
        assert(UploadRange.parse("bytes 8-12/20")?.length == 5)
        assert(UploadRange.parse("bytes 8-12/21", fileSize: 20) == nil)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("phone-delivery-\(UUID())")
        let root = work.appendingPathComponent("Store")
        defer { try? FileManager.default.removeItem(at: work) }
        var store = try TransferStore(rootDirectory: root)
        let file = try store.receiveExchangeTextFile(filename: "AI 결과.md", content: "휴대폰에서도 확인", mimeType: "text/markdown")
        try check(store.pendingForGalaxy().contains { $0.id == file.id })
        try check(try store.aiSharedFiles(offset: 0, limit: 50).items.isEmpty)
        let original = root.appendingPathComponent("AI Exchange/" + file.id)
        try check(try String(contentsOf: original, encoding: .utf8) == "휴대폰에서도 확인")
        store = try TransferStore(rootDirectory: root)
        let pending = store.pendingForGalaxy().first { $0.id == file.id }!
        assert(pending.name == "AI 결과.md" && pending.mimeType == "text/markdown" && pending.sha256 == file.sha256)
        assert(store.item(for: file.id)?.id == file.id)
        assert(store.fileURL(for: file.id) == original)
        try store.acknowledge(file.id)
        try store.acknowledge(file.id)
        assert(!store.pendingForGalaxy().contains { $0.id == file.id })
        assert(store.aiExchangeItems().contains { $0.id == file.id })
        try check(try String(contentsOf: original, encoding: .utf8) == "휴대폰에서도 확인")
        store = try TransferStore(rootDirectory: root)
        assert(!store.pendingForGalaxy().contains { $0.id == file.id })
        try store.queueLibraryItemForPhone(file.id)
        assert(store.pendingForGalaxy().contains { $0.id == file.id })
        try store.acknowledge(file.id)
        assert(!store.pendingForGalaxy().contains { $0.id == file.id })
        let cancelled = try store.receiveExchangeTextFile(filename: "cancel.txt", content: "keep on Mac", mimeType: "text/plain")
        try store.cancelOutgoingItem(cancelled.id)
        assert(!store.pendingForGalaxy().contains { $0.id == cancelled.id })
        assert(store.aiExchangeItems().contains { $0.id == cancelled.id })
        let deleted = try store.receiveExchangeTextFile(filename: "gone.txt", content: "delete before phone opens", mimeType: "text/plain")
        try store.deleteAIExchangeFile(deleted.id)
        assert(!store.pendingForGalaxy().contains { $0.id == deleted.id })
        let absent = try store.receiveExchangeTextFile(filename: "absent.txt", content: "missing actual file", mimeType: "text/plain")
        try FileManager.default.removeItem(at: root.appendingPathComponent("AI Exchange/" + absent.id))
        assert(!store.pendingForGalaxy().contains { $0.id == absent.id })
        let source = try store.receiveFileData(Data("from phone".utf8), name: "phone.txt", mimeType: "text/plain")
        _ = try store.addInboxFileToAIExchange(source.id)
        assert(store.pendingForGalaxy().isEmpty)
        try store.queueLibraryItemForPhone(source.id)
        assert(store.pendingForGalaxy().contains { $0.id == source.id })
        try store.acknowledge(source.id)
        assert(!store.pendingForGalaxy().contains { $0.id == source.id })
        assert(store.inboxItems().contains { $0.id == source.id })
        let jobs = TransferJobs(store: store)
        let job = try jobs.submit(TransferJobRequest(operation: .receiveTextFile, filename: "ordinary-ai.txt", content: "AI ordinary receipt"))
        for _ in 0..<1000 {
            if try jobs.get(job.id).terminal { break }
            Thread.sleep(forTimeInterval: 0.001)
        }
        try check(try jobs.get(job.id).status == "succeeded")
        let receipt = store.inboxItems().first { $0.name == "ordinary-ai.txt" }!
        assert(store.pendingForGalaxy().contains { $0.id == receipt.id })
        try store.acknowledge(receipt.id)
        assert(!store.pendingForGalaxy().contains { $0.id == receipt.id })
        assert(store.inboxItems().contains { $0.id == receipt.id })
        try check(try Data(contentsOf: store.fileURL(for: receipt.id)!) == Data("AI ordinary receipt".utf8))
        let again = try jobs.submit(TransferJobRequest(operation: .receiveTextFile, filename: "ordinary-ai.txt", content: "AI ordinary receipt"))
        for _ in 0..<1000 {
            if try jobs.get(again.id).terminal { break }
            Thread.sleep(forTimeInterval: 0.001)
        }
        try check(try jobs.get(again.id).status == "succeeded")
        assert(store.pendingForGalaxy().contains { $0.id == receipt.id })
        let saveFolder = work.appendingPathComponent("Saved")
        try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        var settings = store.receiptSettings()
        settings.folderPath = saveFolder.path
        _ = try store.updateReceiptSettings(settings)
        let saved = try store.acceptReceivedItem(receipt.id)
        assert(store.pendingForGalaxy().contains { $0.id == saved.id })
        try store.cancelOutgoingItem(saved.id)
        assert(!store.pendingForGalaxy().contains { $0.id == saved.id })
        assert(FileManager.default.fileExists(atPath: saved.savedPath!))
        store = try TransferStore(rootDirectory: root)
        assert(store.pendingForGalaxy().isEmpty)
        print("PASS: AI file delivery persists offline/restart; ACK/cancel keep Mac original; no AI read grant; deleted/missing/source copies excluded")
    }
}
