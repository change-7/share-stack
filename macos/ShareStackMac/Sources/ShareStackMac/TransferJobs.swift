import Foundation
import UniformTypeIdentifiers

struct TransferJobRequest: Codable, Sendable {
    enum Operation: String, Codable, Sendable {
        case receive, receiveAll, cancelInbox, cancelOutbox, sendText, sendFiles, importFiles
    }
    let operation: Operation
    var itemIDs: [String]?
    var filePaths: [String]?
    var text: String?

    func validate() throws {
        switch operation {
        case .receive, .cancelInbox, .cancelOutbox:
            guard let itemIDs, (1...100).contains(itemIDs.count), itemIDs.allSatisfy({ UUID(uuidString: $0) != nil }) else {
                throw JobError.invalidInput
            }
        case .receiveAll: break
        case .sendText:
            guard let text, !text.isEmpty, text.utf8.count <= 512 * 1024 else { throw JobError.invalidInput }
        case .sendFiles, .importFiles:
            guard let filePaths, (1...16).contains(filePaths.count),
                  filePaths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else { throw JobError.invalidInput }
        }
    }
}

struct TransferJob: Codable, Sendable {
    struct Failure: Codable, Sendable {
        let target: String
        let error: String
    }
    let id: String
    let operation: TransferJobRequest.Operation
    var status: String
    let createdAt: Date
    var updatedAt: Date
    var total: Int
    var completed: Int
    var results: [TransferItem]
    var failures: [Failure]

    var terminal: Bool { ["succeeded", "partial_failure", "failed", "cancelled", "interrupted"].contains(status) }
}

enum JobError: LocalizedError {
    case invalidInput, notFound
    var errorDescription: String? {
        switch self {
        case .invalidInput: return "작업 입력이 올바르지 않습니다"
        case .notFound: return "작업을 찾을 수 없습니다"
        }
    }
}

final class TransferJobs: @unchecked Sendable {
    private let store: TransferStore
    private let directory: URL
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "com.pdg.sharestack.jobs", qos: .userInitiated)
    private var jobs: [String: TransferJob] = [:]
    private var changeHandler: (() -> Void)?

    init(store: TransferStore) throws {
        self.store = store
        directory = try GUIBridge.directory().appendingPathComponent("jobs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            var job = try JSONDecoder().decode(TransferJob.self, from: Data(contentsOf: file))
            if !job.terminal {
                job.status = "interrupted"
                job.updatedAt = Date()
                try Self.write(job, to: file)
            }
            jobs[job.id] = job
        }
    }

    func setChangeHandler(_ handler: (() -> Void)?) {
        lock.lock()
        changeHandler = handler
        lock.unlock()
    }

    func submit(_ request: TransferJobRequest) throws -> TransferJob {
        try request.validate()
        let job = TransferJob(id: UUID().uuidString.lowercased(), operation: request.operation, status: "queued",
                              createdAt: Date(), updatedAt: Date(), total: 0, completed: 0, results: [], failures: [])
        lock.lock()
        do {
            try saveLocked(job)
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        worker.async { [self] in execute(request, id: job.id) }
        return job
    }

    func get(_ id: String) throws -> TransferJob {
        lock.lock()
        defer { lock.unlock() }
        guard let job = jobs[id] else { throw JobError.notFound }
        return job
    }

    func list(limit: Int, offset: Int) -> [TransferJob] {
        lock.lock()
        defer { lock.unlock() }
        return Array(jobs.values.sorted { $0.createdAt > $1.createdAt }.dropFirst(offset).prefix(limit))
    }

    func cancel(_ id: String) throws -> TransferJob {
        lock.lock()
        defer { lock.unlock() }
        guard var job = jobs[id] else { throw JobError.notFound }
        if job.terminal { return job }
        job.status = job.status == "queued" ? "cancelled" : "cancelling"
        job.updatedAt = Date()
        try saveLocked(job)
        return job
    }

    private func update(_ id: String, _ body: (inout TransferJob) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var job = jobs[id] else { throw JobError.notFound }
        body(&job)
        job.updatedAt = Date()
        try saveLocked(job)
    }

    private func saveLocked(_ job: TransferJob) throws {
        try Self.write(job, to: directory.appendingPathComponent(job.id + ".json"))
        jobs[job.id] = job
    }

    private static func write(_ job: TransferJob, to file: URL) throws {
        try JSONEncoder().encode(job).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func notifyChanges() {
        lock.lock()
        let handler = changeHandler
        lock.unlock()
        handler?()
    }

    private func execute(_ request: TransferJobRequest, id: String) {
        do {
            if try get(id).terminal { return }
            try update(id) { if $0.status == "queued" { $0.status = "running" } }
            if try get(id).terminal { return }
            let targets: [String]
            switch request.operation {
            case .receiveAll: targets = store.inboxItems().map(\.id)
            case .sendFiles, .importFiles: targets = request.filePaths ?? []
            case .sendText: targets = ["text"]
            default: targets = request.itemIDs?.map { $0.lowercased() } ?? []
            }
            try update(id) { $0.total = targets.count }
            for target in targets {
                let current = try get(id)
                if current.status == "cancelling" || current.status == "cancelled" { break }
                do {
                    var result: TransferItem?
                    switch request.operation {
                    case .receive, .receiveAll: result = try store.acceptReceivedItem(target)
                    case .cancelInbox: try store.cancelReceivedItem(target)
                    case .cancelOutbox: try store.cancelOutgoingItem(target)
                    case .sendText: result = try store.enqueueText(request.text ?? "")
                    case .sendFiles, .importFiles:
                        let url = URL(fileURLWithPath: target)
                        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw JobError.invalidInput }
                        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                        if request.operation == .importFiles {
                            result = try store.importReceivedFile(url, mimeType: mimeType)
                        } else {
                            result = try store.enqueueFile(url, mimeType: mimeType)
                        }
                    }
                    try update(id) {
                        $0.completed += 1
                        if let result { $0.results.append(result) }
                    }
                } catch {
                    try update(id) {
                        $0.completed += 1
                        $0.failures.append(.init(target: target, error: error.localizedDescription))
                    }
                }
                notifyChanges()
            }
            try update(id) {
                if $0.status == "cancelled" { return }
                if $0.completed < $0.total {
                    $0.status = "cancelled"
                } else if $0.failures.isEmpty {
                    $0.status = "succeeded"
                } else {
                    $0.status = $0.failures.count == $0.total ? "failed" : "partial_failure"
                }
            }
        } catch {
            lock.lock()
            if var job = jobs[id] {
                job.status = "failed"
                job.failures.append(.init(target: id, error: error.localizedDescription))
                jobs[id] = job
                try? Self.write(job, to: directory.appendingPathComponent(id + ".json"))
            }
            lock.unlock()
            FileHandle.standardError.write(Data("Share Stack job failed: \(error.localizedDescription)\n".utf8))
        }
        notifyChanges()
    }
}
