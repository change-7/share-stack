import Foundation

final class TransferStore {
    struct Item { let id: String }
    private let enqueueTextStarted: DispatchSemaphore?
    private let releaseEnqueueText: DispatchSemaphore?

    init(blockingEnqueueText: (DispatchSemaphore, DispatchSemaphore)? = nil) {
        enqueueTextStarted = blockingEnqueueText?.0
        releaseEnqueueText = blockingEnqueueText?.1
    }

    func inboxItems() -> [Item] { [] }
    func acceptReceivedItem(_ id: String) throws -> Item { Item(id: id) }
    func cancelReceivedItem(_ id: String) throws {}
    func cancelOutgoingItem(_ id: String) throws {}
    func enqueueText(_ text: String) throws -> Item {
        enqueueTextStarted?.signal()
        if let releaseEnqueueText { releaseEnqueueText.wait() }
        return Item(id: text)
    }
    func receiveFileData(_ data: Data, name: String, mimeType: String, phoneDeliveryPending: Bool = false) throws -> Item { Item(id: name) }
    func importReceivedFile(_ url: URL, mimeType: String) throws -> Item { Item(id: url.path) }
    func enqueueFile(_ url: URL, mimeType: String) throws -> Item { Item(id: url.path) }
}

@main
struct JobRetentionRegression {
    final class Clock {
        private let lock = NSLock()
        private var date = Date()
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
        func advance(_ seconds: TimeInterval) { lock.lock(); date.addTimeInterval(seconds); lock.unlock() }
    }

    static func finished(_ jobs: TransferJobs, _ request: TransferJobRequest) throws -> TransferJob {
        let submitted = try jobs.submit(request)
        for _ in 0..<1000 {
            let job = try jobs.get(submitted.id)
            if job.terminal { return job }
            Thread.sleep(forTimeInterval: 0.001)
        }
        fatalError("Job did not finish")
    }

    static func missing(_ jobs: TransferJobs, _ id: String) {
        do { _ = try jobs.get(id); fatalError("Expired job still available") }
        catch JobError.notFound {}
        catch { fatalError("Unexpected error: \(error)") }
    }

    static func waitForTerminal(_ jobs: TransferJobs, _ id: String) throws -> TransferJob {
        for _ in 0..<1_000 {
            let job = try jobs.get(id)
            if job.terminal { return job }
            Thread.sleep(forTimeInterval: 0.001)
        }
        fatalError("Cancelled job did not finish")
    }

    static func main() throws {
        let clock = Clock()
        let jobs = TransferJobs(store: TransferStore(), now: clock.now)
        let request = TransferJobRequest(operation: .sendText, text: "test")
        let first = try finished(jobs, request)
        assert(first.status == "succeeded" && first.completed == 1)
        let cancelled = try jobs.cancel(first.id)
        assert(cancelled.status == "succeeded")
        clock.advance(599)
        let retained = try jobs.get(first.id)
        assert(retained.status == "succeeded")
        clock.advance(1)
        missing(jobs, first.id)

        var ids: [String] = []
        for _ in 0..<21 {
            clock.advance(1)
            ids.append(try finished(jobs, request).id)
        }
        missing(jobs, ids[0])
        for id in ids.dropFirst() {
            let job = try jobs.get(id)
            assert(job.status == "succeeded")
        }
        let failed = try finished(jobs, TransferJobRequest(operation: .sendFiles, filePaths: ["/nonexistent/sharestack-retention-test"]))
        assert(failed.status == "failed" && failed.failures.count == 1)

        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let blockedJobs = TransferJobs(store: TransferStore(blockingEnqueueText: (started, release)))
        let active = try blockedJobs.submit(request)
        precondition(started.wait(timeout: .now() + 2) == .success)
        let cancellation = try blockedJobs.cancel(active.id)
        assert(cancellation.status == "cancelling")
        release.signal()
        let finalState = try waitForTerminal(blockedJobs, active.id)
        assert(finalState.status == "cancelled")
        clock.advance(600)
        missing(jobs, failed.id)
        print("PASS: success/failure retention, terminal cancellation, 600-second expiry and 20-job limit")
    }
}
