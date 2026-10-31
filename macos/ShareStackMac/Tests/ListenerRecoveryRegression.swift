import Darwin
import Foundation

@main struct ListenerRecoveryRegression {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("listener-recovery-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TransferStore(rootDirectory: root.appendingPathComponent("store"))
        let identity = try TLSIdentity(directory: root.appendingPathComponent("tls"), archivePassword: UUID().uuidString)
        let blocker = socket(AF_INET, SOCK_STREAM, 0)
        precondition(blocker >= 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(blocker, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        precondition(bound == 0 && listen(blocker, 1) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        precondition(withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(blocker, $0, &length) } } == 0)
        let server = try TransferHTTPServer(store: store, token: "phone-fixture", aiToken: "ai-fixture", tlsIdentity: identity, listeningPort: UInt16(bigEndian: address.sin_port))
        let failed = DispatchSemaphore(value: 0), ready = DispatchSemaphore(value: 0)
        server.statusHandler = { value in
            if value.contains("오류") { failed.signal() }
            if value.contains("준비됨") { ready.signal() }
        }
        try server.start()
        precondition(failed.wait(timeout: .now() + 5) == .success, "Fixture did not produce occupied-port failure")
        close(blocker)
        precondition(ready.wait(timeout: .now() + 5) == .success, "Listener never recovered after occupied port was released")
        print("PASS listener recovers from transient EADDRINUSE without relaunch or identity reset")
    }
}
