import Foundation

@main
struct InboxStorageRegression {
    static func check(_ condition: @autoclosure () throws -> Bool) throws {
        let result = try condition()
        precondition(result)
    }

    static func main() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("sharestack-storage-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let root = work.appendingPathComponent("Store")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let settingsFile = root.appendingPathComponent("receipt-settings.json")
        let saved = work.appendingPathComponent("Saved")
        // Old settings have no inboxFolderPath and must keep using the original folder.
        try JSONSerialization.data(withJSONObject: ["mode": "inbox", "folderPath": saved.path])
            .write(to: settingsFile)
        let store = try TransferStore(rootDirectory: root)
        let originalFolder = URL(fileURLWithPath: store.receiptSettings().inboxFolderPath!)
        assert(originalFolder == root.appendingPathComponent("inbox-temporary"))
        var compatible = store.receiptSettings()
        compatible.mode = .automatic
        try store.updateReceiptSettings(compatible)
        compatible.mode = .inbox
        try store.updateReceiptSettings(compatible)
        assert(store.receiptSettings().inboxFolderPath == originalFolder.path)
        let content = Data("# 임시 보관 테스트\n日本語 🎬\n".utf8)
        let first = try store.receiveFileData(content, name: "original.md", mimeType: "text/markdown")
        let oldFile = originalFolder.appendingPathComponent(first.id)
        assert(fm.fileExists(atPath: oldFile.path))

        let selected = work.appendingPathComponent("Selected")
        let requested = selected.appendingPathComponent("ShareStack Inbox")
        try fm.createDirectory(at: requested, withIntermediateDirectories: true)
        let sentinel = requested.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        var settings = store.receiptSettings()
        settings.inboxFolderPath = requested.path
        try store.updateReceiptSettings(settings)
        let current = URL(fileURLWithPath: store.receiptSettings().inboxFolderPath!)
        assert(current.lastPathComponent == "ShareStack Inbox (1)")
        try check(try Data(contentsOf: sentinel) == Data("keep".utf8))
        assert(!fm.fileExists(atPath: oldFile.path))
        try check(try Data(contentsOf: current.appendingPathComponent(first.id)) == content)
        try check(try store.readSharedFile(first.id, offset: 0, limit: 4096).content == String(decoding: content, as: UTF8.self))
        let reloaded = try TransferStore(rootDirectory: root)
        assert(reloaded.receiptSettings().inboxFolderPath == current.path)
        try check(try reloaded.readSharedFile(first.id, offset: 0, limit: 4096).content == String(decoding: content, as: UTF8.self))
        print("PASS legacy settings, safe migration, collision protection, MCP reads and restart")

        let second = try store.receiveFileData(Data("second".utf8), name: "second.txt", mimeType: "text/plain")
        assert(fm.fileExists(atPath: current.appendingPathComponent(second.id).path))
        try store.cancelReceivedItem(second.id)
        assert(!fm.fileExists(atPath: current.appendingPathComponent(second.id).path))
        do { _ = try store.sharedFileInfo(second.id); assertionFailure("Deleted item is readable") }
        catch TransferStore.StoreError.sharedFileNotFound {}
        let accepted = try store.acceptReceivedItem(first.id)
        try check(try Data(contentsOf: URL(fileURLWithPath: accepted.savedPath!)) == content)
        assert(!fm.fileExists(atPath: current.appendingPathComponent(first.id).path))
        try store.cancelReceivedItem(accepted.id)
        assert(!store.savedReceivedItems().contains { $0.id == accepted.id })
        try check(try Data(contentsOf: URL(fileURLWithPath: accepted.savedPath!)) == content)
        print("PASS new receipts use selected folder; inbox deletion deletes real file; acceptance preserves saved file")

        let pending = try store.receiveFileData(Data("rollback".utf8), name: "pending.txt", mimeType: "text/plain")
        let pendingFile = current.appendingPathComponent(pending.id)
        let nextParent = work.appendingPathComponent("Next")
        try fm.createDirectory(at: nextParent, withIntermediateDirectories: true)
        let next = nextParent.appendingPathComponent("ShareStack Inbox")
        var changed = store.receiptSettings()
        changed.inboxFolderPath = next.path
        let previousSettings = try Data(contentsOf: settingsFile)
        try fm.removeItem(at: settingsFile)
        try fm.createDirectory(at: settingsFile, withIntermediateDirectories: false)
        do { try store.updateReceiptSettings(changed); assertionFailure("Settings write should fail") }
        catch {}
        assert(store.receiptSettings().inboxFolderPath == current.path)
        try check(try Data(contentsOf: pendingFile) == Data("rollback".utf8))
        assert(!fm.fileExists(atPath: next.path))
        try fm.removeItem(at: settingsFile)
        try previousSettings.write(to: settingsFile)

        let outside = work.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        try fm.removeItem(at: pendingFile)
        try fm.createSymbolicLink(at: pendingFile, withDestinationURL: outside)
        do { try store.updateReceiptSettings(changed); assertionFailure("Symlink source should fail") }
        catch TransferStore.StoreError.sharedFileUnavailable {}
        try check(try Data(contentsOf: outside) == Data("outside".utf8))
        assert(!fm.fileExists(atPath: next.path))
        assert(store.receiptSettings().inboxFolderPath == current.path)
        try fm.removeItem(at: pendingFile)
        try Data("rollback".utf8).write(to: pendingFile)
        try store.cancelReceivedItem(pending.id)
        assert(!fm.fileExists(atPath: pendingFile.path))
        print("PASS settings-write failure rollback, symlink rejection and actual file deletion after migration")
    }
}
