import Foundation
import Combine

@MainActor
final class RecoveryCenterModel: ObservableObject {
    let store: RecoveryStore
    @Published private(set) var entries: [RecoveryEntry] = []
    @Published private(set) var warnings: [String] = []
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var error: String?

    init(store: RecoveryStore) { self.store = store }

    var retainedBytes: Int64 {
        entries.filter { $0.canRestore || $0.state == .purgeFailed }.reduce(0) {
            let sum = $0.addingReportingOverflow($1.bytes)
            return sum.overflow ? Int64.max : sum.partialValue
        }
    }

    func refresh() async {
        do {
            let catalog = try await store.catalog()
            entries = catalog.entries
            warnings = catalog.warnings
        } catch { self.error = error.localizedDescription }
    }

    func restore(_ id: UUID) async {
        guard !busy else { return }
        busy = true; error = nil; message = nil
        defer { busy = false }
        do {
            let outcome = try await store.restore(id)
            message = outcome.warning ?? String(localized: "Restored to the original location.")
        } catch { self.error = error.localizedDescription }
        await refresh()
    }

    func purge(_ id: UUID, confirmed: Bool) async {
        guard !busy else { return }
        busy = true; error = nil; message = nil
        defer { busy = false }
        do {
            _ = try await store.purge(id, confirmed: confirmed)
            message = String(localized: "The recovery copy was permanently deleted.")
        } catch { self.error = error.localizedDescription }
        await refresh()
    }
}
