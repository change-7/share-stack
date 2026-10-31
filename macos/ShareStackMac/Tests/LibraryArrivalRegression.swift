import Foundation
@main struct LibraryArrivalRegression {
    static func main() {
        var tracker = LibraryArrivalTracker()
        assert(!tracker.update(["existing"]))
        assert(!tracker.update(["existing"]))
        assert(tracker.update(["existing", "new"]))
        assert(!tracker.update(["new"]))
        assert(!tracker.update(["existing", "new"]))
        assert(tracker.update(["existing", "new", "batch1", "batch2"]))
        var empty = LibraryArrivalTracker()
        assert(!empty.update([]))
        assert(empty.update(["first"]))
        print("PASS: startup suppressed, new arrivals detected, refresh/deletion/restoration silent, batches coalesced")
    }
}
