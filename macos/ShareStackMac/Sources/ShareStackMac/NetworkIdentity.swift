import Darwin
import Foundation
import LocalAuthentication
import Security

enum NetworkIdentity {
    static let bonjourType = "_sharestack._tcp"

    static func localIPv4Addresses() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let head = first else { return [] }
        defer { freeifaddrs(head) }

        var result = Set<String>()
        var current: UnsafeMutablePointer<ifaddrs>? = head
        while let interface = current {
            let address = interface.pointee.ifa_addr
            if let address, address.pointee.sa_family == sa_family_t(AF_INET),
               interface.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let status = getnameinfo(
                    address,
                    socklen_t(MemoryLayout<sockaddr_in>.size),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if status == 0 {
                    let value = String(cString: host)
                    if isPrivateIPv4(value) { result.insert(value) }
                }
            }
            current = interface.pointee.ifa_next
        }
        return result.sorted()
    }

    static func tailscaleIPv4Addresses() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let head = first else { return [] }
        defer { freeifaddrs(head) }

        var result = Set<String>()
        var current: UnsafeMutablePointer<ifaddrs>? = head
        while let interface = current {
            let address = interface.pointee.ifa_addr
            if let address, address.pointee.sa_family == sa_family_t(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let status = getnameinfo(
                    address,
                    socklen_t(MemoryLayout<sockaddr_in>.size),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if status == 0 {
                    let value = String(cString: host)
                    if isTailscaleIPv4(value) { result.insert(value) }
                }
            }
            current = interface.pointee.ifa_next
        }
        return result.sorted()
    }

    static func isTailscaleIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".")
        guard parts.count == 4, parts[0] == "100",
              let second = Int(parts[1]), (64...127).contains(second) else { return false }
        return parts.dropFirst().allSatisfy { Int($0).map { (0...255).contains($0) } == true }
    }

    static func isPrivateIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".")
        guard parts.count == 4,
              let first = Int(parts[0]), let second = Int(parts[1]),
              parts.dropFirst(2).allSatisfy({ Int($0).map { (0...255).contains($0) } == true }) else { return false }
        return first == 10 || first == 192 && second == 168 || first == 172 && (16...31).contains(second)
    }

    static func bearerToken() throws -> String {
        try storedSecret(account: "pairing-token")
    }

    static func existingBearerToken() throws -> String {
        try storedSecret(account: "pairing-token", create: false)
    }

    static func tlsArchivePassword() throws -> String {
        try storedSecret(account: "tls-archive-password")
    }

    private static func storedSecret(account: String, create: Bool = true) throws -> String {
        let service = "com.pdg.sharestack.mac.bridge"
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if !create {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecSuccess, let data = value as? Data {
            return data.base64URLEncodedString()
        }
        guard status == errSecItemNotFound, create else { throw IdentityError.keychain(status) }

        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard randomStatus == errSecSuccess else { throw IdentityError.random(randomStatus) }
        let data = Data(bytes)
        var add = query
        add.removeValue(forKey: kSecReturnData as String)
        add.removeValue(forKey: kSecMatchLimit as String)
        add[kSecValueData as String] = data
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw IdentityError.keychain(addStatus) }
        return data.base64URLEncodedString()
    }

    enum IdentityError: Error {
        case keychain(OSStatus)
        case random(OSStatus)
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
