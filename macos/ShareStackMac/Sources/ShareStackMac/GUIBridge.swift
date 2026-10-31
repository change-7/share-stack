import AppKit
import CryptoKit
import Foundation
import Security

enum BridgeError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let value): return value }
    }
}

private final class PinnedGUIConnection: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    let fingerprint: String
    init(fingerprint: String) { self.fingerprint = fingerprint }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let certificate = certificates.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let actual = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        guard actual == fingerprint else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class BridgeReply: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Data, Error>?
    func set(_ value: Result<Data, Error>) { lock.lock(); result = value; lock.unlock() }
    func get() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let result else { throw BridgeError.message("GUI 응답이 없습니다") }
        return try result.get()
    }
}

enum GUIBridge {
    private struct Descriptor: Codable { let fingerprint: String }

    static func directory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true).appendingPathComponent("ShareStackMac", isDirectory: true)
    }

    static func publish(fingerprint: String) throws {
        let file = try directory().appendingPathComponent("gui-bridge.json")
        try JSONEncoder().encode(Descriptor(fingerprint: fingerprint)).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func ensureReady(until deadline: Date) throws {
        if (try? request("GET", path: "/v1/health", timeout: 0.5)) != nil { return }
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app" else { throw BridgeError.message("앱 번들 안의 실행 파일로 --mcp를 실행하세요") }
        let launch = Process()
        launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launch.arguments = ["-g", app.path]
        launch.standardOutput = FileHandle.nullDevice
        launch.standardError = FileHandle.standardError
        try launch.run()
        while launch.isRunning && deadline.timeIntervalSinceNow > 1 { Thread.sleep(forTimeInterval: 0.02) }
        if launch.isRunning { launch.terminate() }
        while deadline.timeIntervalSinceNow > 0.6 {
            if (try? request("GET", path: "/v1/health", timeout: 0.4)) != nil { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw BridgeError.message("GUI 연결 준비가 끝나지 않았습니다. 앱의 시작 오류 또는 Keychain 권한을 확인한 뒤 다시 호출하세요")
    }

    static func request(_ method: String, path: String, body: Any? = nil, timeout: TimeInterval, workspaceCredential: String? = nil) throws -> Any {
        guard timeout > 0 else { throw BridgeError.message("GUI 응답 시간이 초과됐습니다. 다시 조회하세요") }
        let descriptor = try JSONDecoder().decode(Descriptor.self, from: Data(contentsOf: directory().appendingPathComponent("gui-bridge.json")))
        let token = try NetworkIdentity.existingAIMCPBearerToken()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: PinnedGUIConnection(fingerprint: descriptor.fingerprint), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: "https://127.0.0.1:8765" + path), path.hasPrefix("/v1/") else {
            throw BridgeError.message("잘못된 GUI API 경로입니다")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let workspaceCredential { request.setValue(workspaceCredential, forHTTPHeaderField: "X-Workspace-Session") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let signal = DispatchSemaphore(value: 0)
        let reply = BridgeReply()
        let task = session.dataTask(with: request) { data, response, error in
            defer { signal.signal() }
            if let error { reply.set(.failure(error)); return }
            guard let response = response as? HTTPURLResponse, let data, data.count <= 8 * 1024 * 1024 else {
                reply.set(.failure(BridgeError.message("GUI 응답이 올바르지 않거나 너무 큽니다")))
                return
            }
            if !(200...299).contains(response.statusCode) {
                let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
                reply.set(.failure(BridgeError.message(message ?? "GUI HTTP \(response.statusCode)")))
            } else {
                reply.set(.success(data))
            }
        }
        task.resume()
        guard signal.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            throw BridgeError.message("GUI 응답 시간이 초과됐습니다. 작업은 get_job으로 다시 조회하세요")
        }
        return try JSONSerialization.jsonObject(with: reply.get())
    }
}
