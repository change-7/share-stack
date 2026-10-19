import CryptoKit
import Foundation
import Network
import Security

struct TLSIdentity {
    let identity: sec_identity_t
    let certificateFingerprint: String

    init() throws {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        try self.init(
            directory: appSupport.appendingPathComponent("ShareStackMac", isDirectory: true),
            archivePassword: NetworkIdentity.tlsArchivePassword()
        )
    }

    init(directory: URL, archivePassword: String) throws {
        guard !archivePassword.isEmpty else { throw IdentityError.invalidIdentity }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let archive = directory.appendingPathComponent("tls-identity-v2.p12")
        if !FileManager.default.fileExists(atPath: archive.path) {
            try Self.createArchive(at: archive, in: directory, password: archivePassword)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
        let (keyIdentity, certificate) = try Self.importIdentity(at: archive, password: archivePassword)
        guard let identity = sec_identity_create(keyIdentity) else { throw IdentityError.invalidIdentity }
        self.identity = identity
        certificateFingerprint = Self.hex(SHA256.hash(data: SecCertificateCopyData(certificate) as Data))
    }

    private static func importIdentity(at archive: URL, password: String) throws -> (SecIdentity, SecCertificate) {
        let data = try Data(contentsOf: archive)
        var options: [String: Any] = [kSecImportExportPassphrase as String: password]
        if #available(macOS 15.0, *) { options[kSecImportToMemoryOnly as String] = true }
        var imported: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &imported)
        guard status == errSecSuccess else { throw IdentityError.importFailed(status) }
        guard let values = imported as? [[String: Any]],
              let first = values.first,
              let identityValue = first[kSecImportItemIdentity as String],
              CFGetTypeID(identityValue as CFTypeRef) == SecIdentityGetTypeID() else {
            throw IdentityError.invalidIdentity
        }
        let keyIdentity = identityValue as! SecIdentity
        var certificate: SecCertificate?
        let certificateStatus = SecIdentityCopyCertificate(keyIdentity, &certificate)
        guard certificateStatus == errSecSuccess else { throw IdentityError.importFailed(certificateStatus) }
        guard let certificate else { throw IdentityError.invalidIdentity }
        return (keyIdentity, certificate)
    }

    private static func createArchive(at archive: URL, in directory: URL, password: String) throws {
        let work = directory.appendingPathComponent("tls-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: work.path)
        defer { try? FileManager.default.removeItem(at: work) }

        let key = work.appendingPathComponent("server.key")
        let certificate = work.appendingPathComponent("server.crt")
        let output = work.appendingPathComponent("identity.p12")
        let legacyArchive = directory.appendingPathComponent("tls-identity.p12")
        let privateKey: P256.Signing.PrivateKey
        if FileManager.default.fileExists(atPath: legacyArchive.path) {
            let legacyPEM = work.appendingPathComponent("legacy.pem")
            try runOpenSSL(["pkcs12", "-in", legacyArchive.path, "-passin", "pass:", "-nodes", "-nocerts", "-out", legacyPEM.path])
            let pem = try String(contentsOf: legacyPEM, encoding: .utf8)
            guard let begin = pem.range(of: "-----BEGIN PRIVATE KEY-----"),
                  let end = pem.range(of: "-----END PRIVATE KEY-----", range: begin.upperBound..<pem.endIndex) else {
                throw IdentityError.invalidIdentity
            }
            privateKey = try P256.Signing.PrivateKey(pemRepresentation: String(pem[begin.lowerBound..<end.upperBound]))
        } else {
            privateKey = P256.Signing.PrivateKey()
        }
        try privateKey.pemRepresentation.write(to: key, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        try runOpenSSL([
            "req", "-x509", "-new", "-key", key.path, "-out", certificate.path,
            "-days", "3650", "-sha256", "-subj", "/CN=ShareStack"
        ])
        try runOpenSSL([
            "pkcs12", "-export", "-out", output.path, "-inkey", key.path, "-in", certificate.path,
            "-passout", "env:SHARESTACK_TLS_PASSWORD"
        ], archivePassword: password)
        _ = try importIdentity(at: output, password: password)
        try Data(contentsOf: output).write(to: archive, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
    }

    private static func runOpenSSL(_ arguments: [String], archivePassword: String? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        if let archivePassword {
            var environment = ProcessInfo.processInfo.environment
            environment["SHARESTACK_TLS_PASSWORD"] = archivePassword
            process.environment = environment
        }
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw IdentityError.generatorUnavailable
        }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw IdentityError.generationFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    enum IdentityError: LocalizedError {
        case generatorUnavailable
        case generationFailed(String)
        case importFailed(OSStatus)
        case invalidIdentity

        var errorDescription: String? {
            switch self {
            case .generatorUnavailable:
                return "TLS 인증서를 만들 수 없습니다 (/usr/bin/openssl 필요)"
            case .generationFailed(let message):
                return "TLS 인증서 생성 실패 · \(message)"
            case .importFailed(let status):
                return "TLS 인증서를 불러오지 못했습니다 (\(status))"
            case .invalidIdentity:
                return "TLS 인증서와 개인키를 확인할 수 없습니다"
            }
        }
    }
}
