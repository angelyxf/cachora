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
        entries.filter { $0.canRestore || $0.canSaveCopy || $0.state == .purgeFailed }.reduce(0) {
            let sum = $0.addingReportingOverflow($1.bytes)
            return sum.overflow ? Int64.max : sum.partialValue
        }
    }

    func refresh() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        await loadCatalog()
    }

    private func loadCatalog() async {
        do {
            let catalog = try await store.catalog()
            guard !Task.isCancelled else { return }
            entries = catalog.entries
            warnings = catalog.warnings
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    func restore(_ id: UUID) async {
        guard !busy else { return }
        busy = true; error = nil; message = nil
        defer { busy = false }
        do {
            let outcome = try await store.restore(id)
            message = outcome.warning ?? String(localized: "Restored to the original location.")
        } catch { self.error = error.localizedDescription }
        await loadCatalog()
    }

    func saveCopy(_ id: UUID, to destination: URL) async {
        guard !busy else { return }
        busy = true; error = nil; message = nil
        defer { busy = false }
        do {
            try await store.saveCopy(id, to: destination)
            message = String(localized: "Copy saved to \(destination.path)")
        } catch { self.error = error.localizedDescription }
        await loadCatalog()
    }

    func purge(_ id: UUID, confirmed: Bool) async {
        guard !busy else { return }
        busy = true; error = nil; message = nil
        defer { busy = false }
        do {
            _ = try await store.purge(id, confirmed: confirmed)
            message = String(localized: "The recovery copy was permanently deleted.")
        } catch { self.error = error.localizedDescription }
        await loadCatalog()
    }
}
