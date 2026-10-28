import CryptoKit
import Foundation
import UniformTypeIdentifiers

enum ShareHandoff {
    static let groupIdentifier = "group.com.pdg.sharestack"
    static let pendingDirectoryName = "ShareStackIncoming"
    static let maximumFiles = 16
    static let maximumItemSize: Int64 = 20 * 1024 * 1024 * 1024

    struct Manifest: Codable {
        let id: String
        let createdAt: Date
        let files: [File]
    }

    struct File: Codable {
        let id: String
        let name: String
        let size: Int64
        let sha256: String
    }

    static func pendingRoot(fileManager: FileManager = .default) throws -> URL {
        guard let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) else {
            throw ShareError.sharedContainerUnavailable
        }
        let root = container.appendingPathComponent(pendingDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ShareError.sharedContainerUnavailable }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        return root
    }

    static func mimeType(for filename: String) -> String {
        UTType(filenameExtension: URL(fileURLWithPath: filename).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { return false }
            digest.update(data: data)
            return true
        }) {}
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    enum ShareError: LocalizedError {
        case sharedContainerUnavailable
        case unsupportedFile
        case itemTooLarge
        case incompleteBatch

        var errorDescription: String? {
            switch self {
            case .sharedContainerUnavailable: return "ShareStack의 공유 저장 공간에 접근할 수 없습니다. 앱 서명과 App Groups 설정을 확인하세요."
            case .unsupportedFile: return "일반 파일만 공유할 수 있습니다."
            case .itemTooLarge: return "파일이 ShareStack의 20 GiB 제한을 초과합니다."
            case .incompleteBatch: return "선택한 파일을 모두 ShareStack으로 복사하지 못했습니다."
            }
        }
    }
}
