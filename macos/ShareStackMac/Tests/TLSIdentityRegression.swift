import CryptoKit
import Foundation
import Security

@main
struct TLSIdentityRegression {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sharestack-tls-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let password = UUID().uuidString
        let fresh = root.appendingPathComponent("fresh")
        let identity = try TLSIdentity(directory: fresh, archivePassword: password)
        let reloaded = try TLSIdentity(directory: fresh, archivePassword: password)
        try require(identity.certificateFingerprint.count == 64, "Missing certificate fingerprint")
        try require(identity.certificateFingerprint == reloaded.certificateFingerprint, "Fingerprint changed on restart")
        print("PASS: fresh identity loads and retains its fingerprint")

        let legacy = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let key = legacy.appendingPathComponent("original.key")
        let certificate = legacy.appendingPathComponent("original.crt")
        let archive = legacy.appendingPathComponent("tls-identity.p12")
        try openssl(["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-keyout", key.path, "-out", certificate.path, "-days", "1", "-nodes", "-subj", "/CN=ShareStack"])
        try openssl(["pkcs12", "-export", "-out", archive.path, "-inkey", key.path, "-in", certificate.path, "-passout", "pass:"])
        let originalArchive = try Data(contentsOf: archive)
        let migrated = try TLSIdentity(directory: legacy, archivePassword: password)
        let migratedReload = try TLSIdentity(directory: legacy, archivePassword: password)
        try require(migrated.certificateFingerprint == migratedReload.certificateFingerprint, "Migration repeated on restart")
        try require(try Data(contentsOf: archive) == originalArchive, "Legacy archive was changed")
        let originalKey = try P256.Signing.PrivateKey(pemRepresentation: String(contentsOf: key, encoding: .utf8))
        guard let nativeIdentity = sec_identity_copy_ref(migrated.identity)?.takeRetainedValue() else {
            throw CheckFailure(message: "Migrated identity unavailable")
        }
        var privateKey: SecKey?
        try require(SecIdentityCopyPrivateKey(nativeIdentity, &privateKey) == errSecSuccess, "Migrated private key unavailable")
        guard let privateKey, let keyData = SecKeyCopyExternalRepresentation(privateKey, nil) else {
            throw CheckFailure(message: "Migrated key cannot be read")
        }
        try require(keyData as Data == originalKey.x963Representation, "Migration replaced the private key")
        print("PASS: legacy archive migrates, preserves its key and remains intact")

        let protectedArchive = legacy.appendingPathComponent("tls-identity-v2.p12")
        let before = try Data(contentsOf: protectedArchive)
        do {
            _ = try TLSIdentity(directory: legacy, archivePassword: "incorrect-password")
            throw CheckFailure(message: "Incorrect password was accepted")
        } catch TLSIdentity.IdentityError.importFailed { }
        try require(try Data(contentsOf: protectedArchive) == before, "Failed import changed the archive")
        print("PASS: incorrect password is rejected without changing the archive")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(message: message) }
    }

    private static func openssl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try require(process.terminationStatus == 0, "Certificate fixture generation failed")
    }

    private struct CheckFailure: Error {
        let message: String
    }
}
