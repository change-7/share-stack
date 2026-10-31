import Foundation

private struct MaliciousAIExchangeIndex: Encodable {
    let aiReadEnabled = true
    let files: [AIExchangeFile]
    let retiredIDs: Set<String> = []
}

@main
struct AIExchangeRegression {
    static func check(_ condition: @autoclosure () throws -> Bool) throws {
        let value = try condition()
        precondition(value)
    }

    @discardableResult static func allow(_ store: TransferStore, _ file: AIExchangeFile) throws -> AIExchangeFile {
        var time: TimeInterval = 0
        let preparation = AIReadPreparation(now: { time })
        time = AIReadPreparation.delay
        return try store.prepareAIRead(sourceID: nil, fileID: file.id, preparation: preparation)
    }

    static func denied(_ store: TransferStore, _ id: String) throws {
        do { _ = try store.aiSharedFileInfo(id); fatalError("Unchecked metadata exposed") }
        catch TransferStore.StoreError.sharedFileNotFound {}
        do { _ = try store.readAIExchangeFile(id, offset: 0, limit: 32); fatalError("Unchecked text exposed") }
        catch TransferStore.StoreError.sharedFileNotFound {}
    }

    static func consentRegression(_ work: URL) throws {
        let root = work.appendingPathComponent("ConsentStore")
        var store = try TransferStore(rootDirectory: root)
        let file = try store.receiveExchangeTextFile(filename: "unchecked.txt", content: "private until checked", mimeType: "text/plain")
        assert(file.aiReadAllowed == false)
        try check(try store.aiSharedFiles(offset: 0, limit: 10).items.isEmpty)
        try denied(store, file.id)
        var time: TimeInterval = 0
        let waiting = AIReadPreparation(now: { time })
        do {
            _ = try store.prepareAIRead(sourceID: nil, fileID: file.id, preparation: waiting)
            fatalError("AI access enabled before grace period")
        } catch TransferStore.StoreError.aiPreparationWaiting {}
        waiting.cancel()
        time = 1
        do {
            _ = try store.prepareAIRead(sourceID: nil, fileID: file.id, preparation: waiting)
            fatalError("Cancelled preparation enabled AI access")
        } catch is CancellationError {}
        try denied(store, file.id)
        _ = try allow(store, file)
        try check(try store.aiSharedFileInfo(file.id).isReadable)
        store.denyAIReadImmediately(file.id)
        try denied(store, file.id)
        try check(try store.aiSharedFiles(offset: 0, limit: 10).items.isEmpty)
        try store.revokeAIRead(file.id)
        try check(try Data(contentsOf: root.appendingPathComponent("AI Exchange/" + file.id)) == Data("private until checked".utf8))
        let restarted = try TransferStore(rootDirectory: root)
        try denied(restarted, file.id)
        let staleRevoke = AIReadPreparation()
        staleRevoke.cancel()
        _ = try allow(restarted, file)
        do {
            try restarted.revokeAIRead(file.id, preparation: staleRevoke)
            fatalError("Stale revocation overwrote a newer grant")
        } catch is CancellationError {}
        try check(try restarted.aiSharedFileInfo(file.id).isReadable)
        print("PASS: default-off list/info/text, grace period, cancelled/stale intents, immediate revoke and restart persistence")

        store = restarted
        let original = try store.receiveFileData(Data(repeating: 65, count: 3 * 1024 * 1024), name: "large.txt", mimeType: "text/plain")
        let before = store.aiExchangeItems().count
        let cancelled = AIReadPreparation(now: { 0 })
        do {
            _ = try store.prepareAIRead(sourceID: original.id, fileID: nil, preparation: cancelled) { _ in cancelled.cancel() }
            fatalError("Cancelled copy was registered")
        } catch is CancellationError {}
        assert(store.aiExchangeItems().count == before)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("AI Exchange").path)
        assert(!files.contains { $0.hasPrefix(".partial-") })
        var copyTime: TimeInterval = 0
        let request = AIReadPreparation(now: { copyTime }); copyTime = 1
        let copy = try store.prepareAIRead(sourceID: original.id, fileID: nil, preparation: request)
        assert(copy.sourceItemID == original.id)
        assert(request.cancel() == copy.id)
        store.denyAIReadImmediately(copy.id)
        try denied(store, copy.id)
        try store.revokeAIRead(copy.id)
        let rows = LibraryItem.combine(inbox: store.inboxItems(), saved: [], exchange: store.aiExchangeItems())
        assert(rows.filter { $0.id == original.id }.count == 1)
        assert(!rows.contains { $0.id == copy.id })
        let duplicateRows = LibraryItem.combine(inbox: [original], saved: [original], exchange: [copy])
        assert(duplicateRows.count == 1)
        var unrelated = file
        unrelated.sourceItemID = original.id
        let separateRows = LibraryItem.combine(inbox: [original], saved: [], exchange: [unrelated])
        assert(separateRows.count == 2 && separateRows.first { $0.id == original.id }?.exchange == nil)
        _ = try allow(store, copy)
        assert(store.aiExchangeItems().count == before + 1)
        try check(store.inboxItems().contains { $0.id == original.id })
        try check(try store.readAIExchangeFile(copy.id, offset: 0, limit: 32).content == String(repeating: "A", count: 32))
        try store.cancelReceivedItem(original.id)
        try denied(store, copy.id)
        assert(!store.aiExchangeItems().contains { $0.id == copy.id })
        assert(!FileManager.default.fileExists(atPath: root.appendingPathComponent("AI Exchange/" + copy.id).path))
        print("PASS: cancelled copy cleanup, source preservation, unique unified rows, snapshot reuse and source cancellation revokes linked copy")

        let legacyRoot = work.appendingPathComponent("LegacyConsentStore")
        let legacy = try TransferStore(rootDirectory: legacyRoot)
        let oldFile = try legacy.receiveExchangeTextFile(filename: "old.txt", content: "legacy bytes", mimeType: "text/plain")
        let index = legacyRoot.appendingPathComponent("AI Exchange/index.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: index)) as! [String: Any]
        var entries = object["files"] as! [[String: Any]]
        entries[0].removeValue(forKey: "aiReadAllowed")
        object["files"] = entries
        try JSONSerialization.data(withJSONObject: object).write(to: index)
        let migrated = try TransferStore(rootDirectory: legacyRoot)
        assert(migrated.aiExchangeItems().count == 1)
        try denied(migrated, oldFile.id)
        try check(try Data(contentsOf: legacyRoot.appendingPathComponent("AI Exchange/" + oldFile.id)) == Data("legacy bytes".utf8))
        print("PASS: legacy files preserved with AI access off")
    }

    static func finished(_ jobs: TransferJobs, _ request: TransferJobRequest) throws -> TransferJob {
        let submitted = try jobs.submit(request)
        for _ in 0..<1_000 {
            let job = try jobs.get(submitted.id)
            if job.terminal { return job }
            Thread.sleep(forTimeInterval: 0.005)
        }
        fatalError("Text receive job did not finish")
    }

    static func main() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("sharestack-ai-exchange-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let root = work.appendingPathComponent("Store")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = work.appendingPathComponent("outside.txt")
        try Data("secret outside".utf8).write(to: outside)
        let poisonedRoot = work.appendingPathComponent("PoisonedStore")
        let poisonedExchange = poisonedRoot.appendingPathComponent("AI Exchange", isDirectory: true)
        try fm.createDirectory(at: poisonedExchange, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let poisonedFile = AIExchangeFile(id: "../../outside.txt", name: "outside.txt", mimeType: "text/plain",
                                          size: 14, sha256: String(repeating: "0", count: 64), createdAt: Date())
        try JSONEncoder().encode(MaliciousAIExchangeIndex(files: [poisonedFile]))
            .write(to: poisonedExchange.appendingPathComponent("index.json"))
        do {
            _ = try TransferStore(rootDirectory: poisonedRoot)
            fatalError("Path-bearing exchange index ID was accepted")
        } catch TransferStore.StoreError.exchangeUnavailable {}
        try check(try Data(contentsOf: outside) == Data("secret outside".utf8))
        print("PASS: malformed persisted IDs are rejected before file access")

        let legacyStore = try TransferStore(rootDirectory: work.appendingPathComponent("LegacyStore"))
        let legacyJobs = TransferJobs(store: legacyStore)
        let legacyRequest = TransferJobRequest(operation: .receiveTextFile, filename: "legacy.md", content: "legacy text")
        try check(try finished(legacyJobs, legacyRequest).status == "succeeded")
        try check(try finished(legacyJobs, legacyRequest).status == "succeeded")
        assert(legacyStore.inboxItems().count == 1)
        assert(legacyStore.aiExchangeItems().isEmpty)
        print("PASS: existing receive_text_file still stores in the ordinary inbox without AI registration")

        let automaticRoot = work.appendingPathComponent("AutomaticStore")
        let savedFolder = work.appendingPathComponent("SavedFiles", isDirectory: true)
        try fm.createDirectory(at: savedFolder, withIntermediateDirectories: true)
        let automaticStore = try TransferStore(rootDirectory: automaticRoot)
        var automaticSettings = automaticStore.receiptSettings()
        automaticSettings.mode = .automatic
        automaticSettings.folderPath = savedFolder.path
        try automaticStore.updateReceiptSettings(automaticSettings)
        let finderShare = try automaticStore.receiveFileData(Data("Finder share".utf8), name: "finder.md", mimeType: "text/markdown")
        assert(finderShare.state == "saved" && automaticStore.savedReceivedItems().contains(finderShare))
        assert(automaticStore.aiExchangeItems().isEmpty)
        let finderExchangeCopy = try automaticStore.addInboxFileToAIExchange(finderShare.id)
        try check(try Data(contentsOf: URL(fileURLWithPath: finderShare.savedPath!)) == Data("Finder share".utf8))
        try allow(automaticStore, finderExchangeCopy)
        try check(try automaticStore.readAIExchangeFile(finderExchangeCopy.id, offset: 0, limit: 32).content == "Finder share")
        print("PASS: automatically saved Finder-style receipt stays unregistered until explicit copy; source is preserved")

        let store = try TransferStore(rootDirectory: root)
        let markdown = String(repeating: "a", count: 32_767) + "한日\n"
        let inboxMarkdown = try store.receiveFileData(Data(markdown.utf8), name: "report.md", mimeType: "text/markdown")
        let inboxSRT = try store.receiveFileData(Data("1\n00:00:01,000 --> 00:00:02,000\n안녕 世界\n".utf8),
                                                  name: "clip.srt", mimeType: "text/plain")
        let duplicateName = try store.receiveFileData(Data("second copy".utf8), name: "report.md", mimeType: "text/markdown")
        do {
            _ = try store.aiSharedFileInfo(inboxMarkdown.id)
            fatalError("Ordinary inbox item was readable through AI Exchange")
        } catch TransferStore.StoreError.sharedFileNotFound {}

        let first = try store.addInboxFileToAIExchange(inboxMarkdown.id)
        let second = try store.addInboxFileToAIExchange(inboxSRT.id)
        let third = try store.addInboxFileToAIExchange(duplicateName.id)
        assert(first.id != inboxMarkdown.id && second.id != inboxSRT.id)
        assert(first.id != third.id && first.name == third.name)
        assert(store.aiExchangeItems().count == 3)
        try check(try store.aiSharedFiles(offset: 0, limit: 10).items.isEmpty)
        for file in [first, second, third] { try denied(store, file.id); try allow(store, file) }
        let inboxFolder = URL(fileURLWithPath: store.receiptSettings().inboxFolderPath!)
        assert(fm.fileExists(atPath: inboxFolder.appendingPathComponent(inboxMarkdown.id).path))
        let exchangeDirectory = root.appendingPathComponent("AI Exchange", isDirectory: true)
        let directoryMode = try fm.attributesOfItem(atPath: exchangeDirectory.path)[.posixPermissions] as? NSNumber
        assert(directoryMode?.intValue == 0o700)
        let copyMode = try fm.attributesOfItem(atPath: exchangeDirectory.appendingPathComponent(first.id).path)[.posixPermissions] as? NSNumber
        assert(copyMode?.intValue == 0o600)

        var offset: Int64 = 0
        var reconstructed = ""
        while true {
            let chunk = try store.readAIExchangeFile(first.id, offset: offset, limit: 32_768)
            reconstructed += chunk.content
            offset = chunk.nextOffset
            if !chunk.hasMore { break }
        }
        assert(reconstructed == markdown)
        let srt = try store.readAIExchangeFile(second.id, offset: 0, limit: 32_768)
        assert(srt.content.contains("안녕 世界"))
        try check(Set(try store.aiSharedFiles(offset: 0, limit: 10).items.map(\.id)) == Set([first.id, second.id, third.id]))
        try check(try store.readAIExchangeFile(third.id, offset: 0, limit: 32).content == "second copy")
        print("PASS: explicit registration only, duplicate names keep separate copies, 0700/0600 permissions, Markdown/SRT UTF-8 chunks")

        let pathNamed = try store.receiveExchangeTextFile(filename: "../outside.txt", content: "exchange only", mimeType: "text/plain")
        try allow(store, pathNamed)
        assert(pathNamed.name == "outside.txt")
        try check(try Data(contentsOf: outside) == Data("secret outside".utf8))
        try check(try store.readAIExchangeFile(pathNamed.id, offset: 0, limit: 32).content == "exchange only")
        let tamperedPath = exchangeDirectory.appendingPathComponent(pathNamed.id)
        try fm.removeItem(at: tamperedPath)
        try Data("exchange evil".utf8).write(to: tamperedPath)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tamperedPath.path)
        do {
            _ = try store.readAIExchangeFile(pathNamed.id, offset: 0, limit: 32)
            fatalError("Modified exchange copy was readable")
        } catch TransferStore.StoreError.sharedFileUnavailable {}

        let symlinked = try store.receiveExchangeTextFile(filename: "link.txt", content: "copy", mimeType: "text/plain")
        try allow(store, symlinked)
        let symlinkPath = exchangeDirectory.appendingPathComponent(symlinked.id)
        try fm.removeItem(at: symlinkPath)
        try fm.createSymbolicLink(at: symlinkPath, withDestinationURL: outside)
        do {
            _ = try store.readAIExchangeFile(symlinked.id, offset: 0, limit: 32)
            fatalError("Exchange symlink read escaped to an outside file")
        } catch TransferStore.StoreError.sharedFileNotFound {}
        try store.deleteAIExchangeFile(symlinked.id)
        try check(try Data(contentsOf: outside) == Data("secret outside".utf8))
        print("PASS: path-like names, modified contents and symbolic links cannot read outside files")

        try store.setAIExchangeEnabled(false)
        do {
            _ = try store.aiSharedFiles(offset: 0, limit: 10)
            fatalError("Disabled AI Exchange still returned a list")
        } catch TransferStore.StoreError.aiExchangeDisabled {}
        let reloaded = try TransferStore(rootDirectory: root)
        assert(!reloaded.aiExchangeEnabled())
        try reloaded.setAIExchangeEnabled(true)
        try check(try reloaded.readAIExchangeFile(second.id, offset: 0, limit: 32_768).content.contains("안녕 世界"))

        let racing = try reloaded.receiveExchangeTextFile(filename: "race.txt", content: "race", mimeType: "text/plain")
        try allow(reloaded, racing)
        let gate = DispatchSemaphore(value: 0)
        let raceGroup = DispatchGroup()
        raceGroup.enter()
        DispatchQueue.global().async {
            gate.wait()
            do { _ = try reloaded.readAIExchangeFile(racing.id, offset: 0, limit: 32) }
            catch TransferStore.StoreError.sharedFileNotFound {}
            catch { preconditionFailure("Unexpected concurrent read error: \(error)") }
            raceGroup.leave()
        }
        raceGroup.enter()
        DispatchQueue.global().async {
            gate.wait()
            do { try reloaded.deleteAIExchangeFile(racing.id) }
            catch { preconditionFailure("Concurrent delete failed: \(error)") }
            raceGroup.leave()
        }
        gate.signal()
        gate.signal()
        precondition(raceGroup.wait(timeout: .now() + 5) == .success)
        do {
            _ = try reloaded.readAIExchangeFile(racing.id, offset: 0, limit: 32)
            fatalError("Read succeeded after concurrent delete completed")
        } catch TransferStore.StoreError.sharedFileNotFound {}

        let beforeDelete = try reloaded.aiSharedFiles(offset: 0, limit: 10).items.map(\.id)
        let deleteTarget = reloaded.aiExchangeItems().first { $0.id == first.id }!
        try reloaded.deleteAIExchangeFile(deleteTarget.id)
        assert(!fm.fileExists(atPath: exchangeDirectory.appendingPathComponent(deleteTarget.id).path))
        assert(!reloaded.aiExchangeItems().contains { $0.id == deleteTarget.id })
        do {
            _ = try reloaded.readAIExchangeFile(deleteTarget.id, offset: 0, limit: 10)
            fatalError("Deleted AI Exchange ID remained readable")
        } catch TransferStore.StoreError.sharedFileNotFound {}
        let afterDelete = try reloaded.aiSharedFiles(offset: 0, limit: 10).items.map(\.id)
        assert(beforeDelete.contains(deleteTarget.id) && !afterDelete.contains(deleteTarget.id))
        let indexData = try Data(contentsOf: exchangeDirectory.appendingPathComponent("index.json"))
        let indexObject = try JSONSerialization.jsonObject(with: indexData) as! [String: Any]
        assert((indexObject["retiredIDs"] as? [String])?.contains(deleteTarget.id) == true)
        let afterRestart = try TransferStore(rootDirectory: root)
        do {
            _ = try afterRestart.aiSharedFileInfo(deleteTarget.id)
            fatalError("Deleted ID returned after restart")
        } catch TransferStore.StoreError.sharedFileNotFound {}
        let replacement = try afterRestart.receiveExchangeTextFile(filename: "new.txt", content: "new", mimeType: "text/plain")
        assert(replacement.id != deleteTarget.id)
        print("PASS: read switch persists; deletion revokes, removes copy and remains denied after restart")

        let phone = "Bearer phone-token"
        let ai = "Bearer ai-token"
        assert(TransferHTTPServer.caller(for: phone, phoneToken: "phone-token", aiToken: "ai-token") == .phone)
        assert(TransferHTTPServer.caller(for: ai, phoneToken: "phone-token", aiToken: "ai-token") == .aiMCP)
        assert(TransferHTTPServer.caller(for: nil, phoneToken: "phone-token", aiToken: "ai-token") == nil)
        assert(TransferHTTPServer.mayAccess("/v1/health", caller: .aiMCP))
        assert(!TransferHTTPServer.mayAccess("/v1/shared-files", caller: .phone))
        assert(!TransferHTTPServer.mayAccess("/v1/inbox", caller: .aiMCP))
        assert(TransferHTTPServer.mayAccess("/v1/ai-exchange/text", caller: .aiMCP))
        assert(!TransferHTTPServer.mayAccess("/v1/ai-exchange/text", caller: .phone))
        assert(!TransferHTTPServer.mayAccess("/v1/items/00000000-0000-0000-0000-000000000000/content", caller: .aiMCP))
        assert(!TransferHTTPServer.maySubmitAIJob(.sendFiles))
        assert(!TransferHTTPServer.maySubmitAIJob(.importFiles))
        assert(TransferHTTPServer.maySubmitAIJob(.receiveTextFile))
        try consentRegression(work)
        print("PASS: authenticated AI health readiness; distinct phone/AI principals; legacy inbox/item and arbitrary path jobs denied to AI")
    }
}
