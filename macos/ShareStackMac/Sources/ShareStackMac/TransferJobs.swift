import Foundation
import UniformTypeIdentifiers

struct TransferJobRequest: Codable, Sendable {
    enum Operation: String, Codable, Sendable {
        case receive, receiveAll, cancelInbox, cancelOutbox, sendText, sendFiles, importFiles, receiveTextFile
    }
    let operation: Operation
    var itemIDs: [String]?
    var filePaths: [String]?
    var text: String?
    var filename: String?
    var content: String?

    func validate() throws {
        switch operation {
        case .receive, .cancelInbox, .cancelOutbox:
            guard let itemIDs, (1...100).contains(itemIDs.count), itemIDs.allSatisfy({ UUID(uuidString: $0) != nil }) else {
                throw JobError.invalidInput
            }
        case .receiveAll: break
        case .sendText:
            guard let text, !text.isEmpty, text.utf8.count <= 512 * 1024 else { throw JobError.invalidInput }
        case .receiveTextFile:
            guard let filename, !filename.isEmpty, filename.utf8.count <= 1024,
                  let content, content.utf8.count <= 128 * 1024 else { throw JobError.invalidInput }
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
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "com.pdg.sharestack.jobs", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private var jobs: [String: TransferJob] = [:]
    private var changeHandler: (() -> Void)?
    private let now: () -> Date
    private let expiryTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.pdg.sharestack.jobs.expiry"))

    init(store: TransferStore, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
        expiryTimer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.pruneLocked()
            self.lock.unlock()
        }
        expiryTimer.resume()
    }

    deinit { expiryTimer.cancel() }

    func setChangeHandler(_ handler: (() -> Void)?) {
        lock.lock()
        changeHandler = handler
        lock.unlock()
    }

    func submit(_ request: TransferJobRequest) throws -> TransferJob {
        try request.validate()
        let job = TransferJob(id: UUID().uuidString.lowercased(), operation: request.operation, status: "queued",
                              createdAt: Date(), updatedAt: Date(), total: 0, completed: 0, failures: [])
        lock.lock()
        saveLocked(job)
        lock.unlock()
        worker.async { [self] in execute(request, id: job.id) }
        return job
    }

    func get(_ id: String) throws -> TransferJob {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked()
        guard let job = jobs[id] else { throw JobError.notFound }
        return job
    }

    func cancel(_ id: String) throws -> TransferJob {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked()
        guard var job = jobs[id] else { throw JobError.notFound }
        if job.terminal { return job }
        job.status = job.status == "queued" ? "cancelled" : "cancelling"
        job.updatedAt = now()
        saveLocked(job)
        return job
    }

    private func update(_ id: String, _ body: (inout TransferJob) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var job = jobs[id] else { throw JobError.notFound }
        guard !job.terminal else { return }
        body(&job)
        job.updatedAt = now()
        saveLocked(job)
    }

    private func saveLocked(_ job: TransferJob) {
        jobs[job.id] = job
        pruneLocked()
    }

    private func pruneLocked() {
        let completed = jobs.values.filter { $0.terminal }.sorted { $0.updatedAt > $1.updatedAt }
        let cutoff = now().addingTimeInterval(-600)
        for (index, job) in completed.enumerated() where index >= 20 || job.updatedAt <= cutoff {
            jobs.removeValue(forKey: job.id)
        }
        if let oldest = jobs.values.filter({ $0.terminal }).map(\.updatedAt).min() {
            expiryTimer.schedule(deadline: .now() + max(0, oldest.addingTimeInterval(600).timeIntervalSince(now())))
        } else {
            expiryTimer.schedule(deadline: .distantFuture)
        }
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
            case .receiveTextFile: targets = [request.filename ?? "file"]
            default: targets = request.itemIDs?.map { $0.lowercased() } ?? []
            }
            try update(id) { $0.total = targets.count }
            for target in targets {
                let current = try get(id)
                if current.status == "cancelling" || current.status == "cancelled" { break }
                do {
                    switch request.operation {
                    case .receive, .receiveAll: _ = try store.acceptReceivedItem(target)
                    case .cancelInbox: try store.cancelReceivedItem(target)
                    case .cancelOutbox: try store.cancelOutgoingItem(target)
                    case .sendText: _ = try store.enqueueText(request.text ?? "")
                    case .receiveTextFile:
                        let filename = request.filename ?? "file"
                        let ext = URL(fileURLWithPath: filename).pathExtension
                        let mimeType = UTType(filenameExtension: ext)?.preferredMIMEType ?? "text/plain"
                        _ = try store.receiveFileData(Data((request.content ?? "").utf8), name: filename,
                                                      mimeType: mimeType, phoneDeliveryPending: true)
                    case .sendFiles, .importFiles:
                        let url = URL(fileURLWithPath: target)
                        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw JobError.invalidInput }
                        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                        if request.operation == .importFiles {
                            _ = try store.importReceivedFile(url, mimeType: mimeType)
                        } else {
                            _ = try store.enqueueFile(url, mimeType: mimeType)
                        }
                    }
                    try update(id) {
                        $0.completed += 1
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
                if $0.status == "cancelling" || $0.completed < $0.total {
                    $0.status = "cancelled"
                } else if $0.failures.isEmpty {
                    $0.status = "succeeded"
                } else {
                    $0.status = $0.failures.count == $0.total ? "failed" : "partial_failure"
                }
            }
        } catch {
            lock.lock()
            if var job = jobs[id], !job.terminal {
                job.status = job.status == "cancelling" ? "cancelled" : "failed"
                job.updatedAt = now()
                if job.status == "failed" {
                    job.failures.append(.init(target: id, error: error.localizedDescription))
                }
                saveLocked(job)
            }
            lock.unlock()
            FileHandle.standardError.write(Data("Share Stack job failed: \(error.localizedDescription)\n".utf8))
        }
        notifyChanges()
    }
}
