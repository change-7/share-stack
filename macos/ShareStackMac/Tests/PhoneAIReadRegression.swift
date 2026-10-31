import CryptoKit
import Foundation

@main
struct PhoneAIReadRegression {
    static func check(_ value: @autoclosure () throws -> Bool) throws { let result = try value(); precondition(result) }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("phone-ai-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var store = try TransferStore(rootDirectory: root)
        let item = try store.receiveFileData(Data("phone consent".utf8), name: "phone.txt", mimeType: "text/plain")
        let other = try store.receiveFileData(Data("unrelated".utf8), name: "other.txt", mimeType: "text/plain")
        try check(try store.aiSharedFiles(offset: 0, limit: 50).items.isEmpty)
        let id = UUID().uuidString.lowercased()
        let allow = PhoneAIReadRequest(id: id, revision: 1, allowed: true, sourceID: item.id, sha256: item.sha256)
        let ready = try store.applyPhoneAIRead(allow)
        assert(ready.ready && ready.revision == 1)
        let copy = store.aiExchangeItems().first { $0.sourceItemID == item.id }!
        try check(try store.readAIExchangeFile(copy.id, offset: 0, limit: 100).content == "phone consent")
        assert(!store.aiExchangeItems().contains { $0.sourceItemID == other.id })
        _ = try store.applyPhoneAIRead(allow)
        assert(store.aiExchangeItems().count == 1)
        let deny = PhoneAIReadRequest(id: id, revision: 2, allowed: false, sourceID: nil, sha256: nil)
        let denied = try store.applyPhoneAIRead(deny)
        assert(!denied.allowed && !denied.ready && denied.revision == 2)
        try check(try store.aiSharedFiles(offset: 0, limit: 50).items.isEmpty)
        do { _ = try store.aiSharedFileInfo(copy.id); fatalError("Revoked metadata exposed") }
        catch TransferStore.StoreError.sharedFileNotFound {}
        do { _ = try store.readAIExchangeFile(copy.id, offset: 0, limit: 100); fatalError("Revoked bytes exposed") }
        catch TransferStore.StoreError.sharedFileNotFound {}
        assert(store.inboxItems().contains { $0.id == item.id })
        store = try TransferStore(rootDirectory: root)
        let stale = try store.applyPhoneAIRead(allow)
        assert(stale.revision == 2 && !stale.allowed)
        try check(try store.aiSharedFiles(offset: 0, limit: 50).items.isEmpty)
        let earlyID = UUID().uuidString.lowercased()
        _ = try store.applyPhoneAIRead(PhoneAIReadRequest(id: earlyID, revision: 2, allowed: false, sourceID: nil, sha256: nil))
        let early = try store.applyPhoneAIRead(PhoneAIReadRequest(id: earlyID, revision: 1, allowed: true, sourceID: item.id, sha256: item.sha256))
        assert(early.revision == 2 && !early.allowed)
        do {
            _ = try store.applyPhoneAIRead(PhoneAIReadRequest(id: id, revision: 2, allowed: true, sourceID: item.id, sha256: item.sha256))
            fatalError("Conflicting retry accepted")
        } catch TransferStore.StoreError.invalidExchangeInput {}
        do {
            _ = try store.applyPhoneAIRead(PhoneAIReadRequest(id: id, revision: 3, allowed: true, sourceID: other.id, sha256: other.sha256))
            fatalError("Consent rebound to unrelated file")
        } catch TransferStore.StoreError.invalidExchangeInput {}
        let missing = UUID().uuidString.lowercased()
        do {
            _ = try store.applyPhoneAIRead(PhoneAIReadRequest(id: missing, revision: 1, allowed: true, sourceID: UUID().uuidString.lowercased(), sha256: item.sha256))
            fatalError("Consent granted to unreceived file")
        } catch TransferStore.StoreError.itemNotInInbox {}
        let again = try store.applyPhoneAIRead(PhoneAIReadRequest(id: id, revision: 3, allowed: true, sourceID: item.id, sha256: item.sha256))
        assert(again.ready && store.aiExchangeItems().count == 1)
        _ = try store.applyPhoneAIRead(PhoneAIReadRequest(id: id, revision: 4, allowed: false, sourceID: nil, sha256: nil))
        let racingID = UUID().uuidString.lowercased()
        var revokedDuringCopy = false
        do {
            _ = try store.applyPhoneAIRead(PhoneAIReadRequest(id: racingID, revision: 1, allowed: true, sourceID: other.id, sha256: other.sha256)) { _ in
                guard !revokedDuringCopy else { return }
                revokedDuringCopy = true
                do { _ = try store.applyPhoneAIRead(PhoneAIReadRequest(id: racingID, revision: 2, allowed: false, sourceID: nil, sha256: nil)) }
                catch { fatalError("Concurrent revoke failed: \(error)") }
            }
            fatalError("Cancelled phone preparation enabled reading")
        } catch is CancellationError {}
        assert(revokedDuringCopy)
        try check(try store.aiSharedFiles(offset: 0, limit: 50).items.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("AI Exchange").path)
        assert(!files.contains { $0.hasPrefix(".partial-") })
        do {
            _ = try store.applyPhoneAIRead(PhoneAIReadRequest(id: UUID().uuidString.lowercased(), revision: 1, allowed: true, sourceID: other.id, sha256: item.sha256))
            fatalError("Wrong content hash accepted")
        } catch TransferStore.StoreError.checksumMismatch {}
        store = try TransferStore(rootDirectory: root)
        let raceRetry = try store.applyPhoneAIRead(PhoneAIReadRequest(id: racingID, revision: 1, allowed: true, sourceID: other.id, sha256: other.sha256))
        assert(raceRetry.revision == 2 && !raceRetry.allowed)
        let macRaceID = UUID().uuidString.lowercased()
        var macRevoked = false
        do {
            _ = try store.applyPhoneAIRead(PhoneAIReadRequest(id: macRaceID, revision: 1, allowed: true, sourceID: item.id, sha256: item.sha256)) { _ in
                guard !macRevoked else { return }
                macRevoked = true
                do { try store.revokeAIRead(copy.id) }
                catch { fatalError("Mac revoke failed: \(error)") }
            }
            fatalError("Older phone grant overrode a newer Mac revoke")
        } catch is CancellationError {}
        assert(macRevoked)
        try check(try store.aiSharedFiles(offset: 0, limit: 50).items.isEmpty)
        store = try TransferStore(rootDirectory: root)
        let afterMacRevoke = try store.applyPhoneAIRead(PhoneAIReadRequest(id: macRaceID, revision: 1, allowed: true, sourceID: item.id, sha256: item.sha256))
        assert(!afterMacRevoke.allowed && !afterMacRevoke.ready)
        try check(try store.aiSharedFiles(offset: 0, limit: 50).items.isEmpty)
        assert(TransferHTTPServer.mayAccess("/v1/phone-ai-read", caller: .phone))
        assert(!TransferHTTPServer.mayAccess("/v1/phone-ai-read", caller: .aiMCP))
        print("PASS: phone grant after verification, exact source, default-off upload, idempotence, revoke, restart, stale/conflicting requests and AI API isolation")
    }
}
