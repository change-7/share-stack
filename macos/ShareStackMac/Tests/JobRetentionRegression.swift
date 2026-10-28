import Foundation

final class TransferStore {
    struct Item { let id: String }
    func inboxItems() -> [Item] { [] }
    func acceptReceivedItem(_ id: String) throws -> Item { Item(id: id) }
    func cancelReceivedItem(_ id: String) throws {}
    func cancelOutgoingItem(_ id: String) throws {}
    func enqueueText(_ text: String) throws -> Item { Item(id: text) }
    func receiveFileData(_ data: Data, name: String, mimeType: String) throws -> Item { Item(id: name) }
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
        clock.advance(600)
        missing(jobs, failed.id)
        print("PASS: success/failure retention, terminal cancellation, 600-second expiry and 20-job limit")
    }
}
