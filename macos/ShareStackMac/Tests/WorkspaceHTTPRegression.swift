import Foundation
import Security

private final class TestTrust: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let trust = challenge.protectionSpace.serverTrust else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
private final class Reply: @unchecked Sendable {
    let lock = NSLock()
    var value: (Int, Data)?
    func set(_ value: (Int, Data)) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> (Int, Data) { lock.lock(); defer { lock.unlock() }; return value ?? (0, Data()) }
}
@main struct WorkspaceHTTPRegression {
    static func check(_ value: @autoclosure () throws -> Bool) throws { let actual = try value(); precondition(actual) }
    static func main() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("workspace-http-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let transfer = try TransferStore(rootDirectory: root.appendingPathComponent("store"))
        let source = root.appendingPathComponent("source")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("first\n".utf8).write(to: source.appendingPathComponent("a.txt"))
        let workspace = try transfer.workspaceStore(), record = try workspace.importFolder(source), id = record.id, fid = record.files[0].id
        let identity = try TLSIdentity(directory: root.appendingPathComponent("tls"), archivePassword: UUID().uuidString)
        let port = UInt16.random(in: 40000...55000)
        let server = try TransferHTTPServer(store: transfer, token: "phone-fixture", aiToken: "ai-fixture", tlsIdentity: identity, listeningPort: port)
        let ready = DispatchSemaphore(value: 0)
        server.statusHandler = { if $0.contains("준비됨") { ready.signal() } }
        try server.start()
        precondition(ready.wait(timeout: .now() + 10) == .success)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: TestTrust(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        func call(_ path: String, method: String = "GET", token: String = "ai-fixture", credential: String? = nil, body: [String: Any]? = nil) throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "https://127.0.0.1:\(port)" + path)!)
            request.httpMethod = method; request.timeoutInterval = 10
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            if let credential { request.setValue(credential, forHTTPHeaderField: "X-Workspace-Session") }
            if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let wait = DispatchSemaphore(value: 0), reply = Reply()
            let task = session.dataTask(with: request) { data, response, _ in reply.set(((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data())); wait.signal() }
            task.resume(); precondition(wait.wait(timeout: .now() + 12) == .success)
            let response = reply.get()
            return (response.0, ((try? JSONSerialization.jsonObject(with: response.1)) as? [String: Any]) ?? [:])
        }
        try check(call("/v1/workspaces", token: "phone-fixture").0 == 403)
        try check(call("/v1/workspaces").0 == 403)
        let registration = try call("/v1/workspace-session", method: "POST", body: ["label": "fixture"])
        precondition(registration.0 == 200)
        let credential = registration.1["credential"] as! String, sessionID = registration.1["id"] as! String
        let second = try call("/v1/workspace-session", method: "POST", body: ["label": "second"]).1["credential"] as! String
        try check((call("/v1/workspaces", credential: credential).1["items"] as! [Any]).isEmpty)
        try workspace.setMode(id, .readOnly, sessionID: sessionID)
        try check((call("/v1/workspaces", credential: credential).1["items"] as! [Any]).count == 1)
        try check((call("/v1/workspaces", credential: second).1["items"] as! [Any]).isEmpty)
        try check(call("/v1/workspaces/\(id)/files/\(fid)/content", credential: credential).1["content"] as? String == "first\n")
        try check(call("/v1/workspaces/\(id)/files/\(fid)", token: "phone-fixture", credential: credential).0 == 403)
        let create: [String: Any] = ["relativePath": "new.txt", "content": "new", "requestKey": "create"]
        try check(call("/v1/workspaces/\(id)/create", method: "POST", credential: credential, body: create).0 == 403)
        let patch: [String: Any] = ["fileId": fid, "expectedHash": record.files[0].sha256, "patch": "--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-first\n+changed\n", "requestKey": "patch"]
        try check(call("/v1/workspaces/\(id)/patch", method: "POST", credential: credential, body: patch).0 == 403)
        try check(call("/v1/items/\(id)/content", token: "phone-fixture").0 == 404)
        try check(call("/v1/inbox/\(id)/accept", method: "POST", token: "phone-fixture").0 == 404)
        try check(call("/v1/inbox/\(id)", method: "DELETE", token: "phone-fixture").0 == 404)
        try check(call("/v1/workspaces/\(id)/mode", method: "POST", credential: credential, body: ["mode": "edit"]).0 == 403)
        for token in ["phone-fixture", "ai-fixture"] {
            try check(call("/v1/jobs", method: "POST", token: token, body: ["operation": "sendFiles", "filePaths": [root.appendingPathComponent("store/Workspaces/\(id)/files/a.txt").path]]).0 == 403)
        }
        try workspace.setMode(id, .edit, sessionID: sessionID)
        try check(call("/v1/workspaces/\(id)/create", method: "POST", credential: second, body: create).0 == 403)
        try check(call("/v1/workspaces/\(id)/create", method: "POST", credential: credential, body: create).0 == 200)
        try check(call("/v1/workspaces/\(id)/create", method: "POST", credential: credential, body: create).0 == 200)
        try check(call("/v1/workspaces/\(id)/patch", method: "POST", credential: credential, body: patch).0 == 200)
        try check(call("/v1/workspaces/\(id)/changes?limit=1", credential: credential).0 == 200)
        try transfer.setAIExchangeEnabled(false)
        try check(call("/v1/workspaces/\(id)/files/\(fid)", credential: credential).0 == 403)
        try transfer.setAIExchangeEnabled(true)
        try workspace.setMode(id, .privateMode)
        try check(call("/v1/workspaces/\(id)/files/\(fid)", credential: credential).0 == 403)
        let normal = try call("/v1/jobs", method: "POST", token: "phone-fixture", body: ["operation": "receiveTextFile", "filename": "normal.txt", "content": "normal phone API"])
        precondition(normal.0 == 201)
        let jobID = normal.1["id"] as! String
        var completed = false
        for _ in 0..<100 {
            let status = try call("/v1/jobs/" + jobID, token: "phone-fixture").1["status"] as? String
            if status == "succeeded" { completed = true; break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        precondition(completed)
        try check(Data(contentsOf: source.appendingPathComponent("a.txt")) == Data("first\n".utf8))
        print("PASS live HTTPS: pending/approved session isolation, phone denial, read-only denial, no elevation route, legacy path closure, edit/replay, global off, revoke and normal text receive")
    }
}
