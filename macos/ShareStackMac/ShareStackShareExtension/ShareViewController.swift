import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

final class ShareViewController: NSViewController {
    private let message = NSTextField(labelWithString: "ShareStack으로 복사 중…")
    private var didStart = false

    override func loadView() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 90))
        message.alignment = .center
        message.frame = content.bounds.insetBy(dx: 16, dy: 20)
        message.autoresizingMask = [.width, .height]
        content.addSubview(message)
        view = content
        preferredContentSize = content.frame.size
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !didStart else { return }
        didStart = true
        receiveSelection()
    }

    private func receiveSelection() {
        guard let context = extensionContext else { return }
        let providers = context.inputItems.compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard (1...ShareHandoff.maximumFiles).contains(providers.count) else {
            context.cancelRequest(withError: ShareHandoff.ShareError.incompleteBatch)
            return
        }

        do {
            let batchID = UUID().uuidString.lowercased()
            let batch = try ShareHandoff.pendingRoot().appendingPathComponent(batchID, isDirectory: true)
            let files = batch.appendingPathComponent("files", isDirectory: true)
            try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let group = DispatchGroup()
            let lock = NSLock()
            var entries: [ShareHandoff.File] = []
            var failed = false

            for provider in providers {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    defer { group.leave() }
                    let url = (item as? URL) ?? (item as? Data).flatMap {
                        URL(dataRepresentation: $0, relativeTo: nil)
                    }
                    guard let url, url.isFileURL, error == nil else {
                        lock.lock()
                        failed = true
                        lock.unlock()
                        return
                    }
                    do {
                        let entry = try Self.copy(url, to: files)
                        lock.lock()
                        entries.append(entry)
                        lock.unlock()
                    } catch {
                        lock.lock()
                        failed = true
                        lock.unlock()
                    }
                }
            }

            group.notify(queue: .global(qos: .utility)) {
                lock.lock()
                let copied = entries
                let didFail = failed || copied.count != providers.count
                lock.unlock()
                guard !didFail else {
                    try? FileManager.default.removeItem(at: batch)
                    context.cancelRequest(withError: ShareHandoff.ShareError.incompleteBatch)
                    return
                }
                do {
                    let manifest = ShareHandoff.Manifest(id: batchID, createdAt: Date(), files: copied)
                    let data = try JSONEncoder().encode(manifest)
                    let url = batch.appendingPathComponent("manifest.json")
                    try data.write(to: url, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    context.completeRequest(returningItems: nil)
                } catch {
                    try? FileManager.default.removeItem(at: batch)
                    context.cancelRequest(withError: error)
                }
            }
        } catch {
            context.cancelRequest(withError: error)
        }
    }

    private static func copy(_ source: URL, to directory: URL) throws -> ShareHandoff.File {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let sourceDescriptor = open(source.path, O_RDONLY | O_NOFOLLOW)
        guard sourceDescriptor >= 0 else { throw ShareHandoff.ShareError.unsupportedFile }
        let input = FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var sourceInfo = stat()
        guard fstat(sourceDescriptor, &sourceInfo) == 0,
              sourceInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), sourceInfo.st_size >= 0 else {
            throw ShareHandoff.ShareError.unsupportedFile
        }
        let size = Int64(sourceInfo.st_size)
        guard size <= ShareHandoff.maximumItemSize else { throw ShareHandoff.ShareError.itemTooLarge }

        let id = UUID().uuidString.lowercased()
        let destination = directory.appendingPathComponent(id + ".data")
        let destinationDescriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(S_IRUSR | S_IWUSR))
        guard destinationDescriptor >= 0 else { throw ShareHandoff.ShareError.incompleteBatch }
        let output = FileHandle(fileDescriptor: destinationDescriptor, closeOnDealloc: true)
        defer { try? output.close() }
        do {
            var copiedSize: Int64 = 0
            while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
                try output.write(contentsOf: data)
                copiedSize += Int64(data.count)
            }
            try output.synchronize()
            var copiedInfo = stat()
            guard lstat(destination.path, &copiedInfo) == 0,
                  copiedInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  copiedSize == size, Int64(copiedInfo.st_size) == size else {
                throw ShareHandoff.ShareError.incompleteBatch
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return ShareHandoff.File(id: id, name: source.lastPathComponent, size: size,
                                     sha256: try ShareHandoff.sha256(destination))
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
