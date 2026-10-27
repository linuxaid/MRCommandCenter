import Foundation
import Observation

/// Adding and removing an MR's labels (#27), from the project's existing labels.
/// One per open label picker; the brief's remove buttons use `LabelEditor.remove` directly.
@Observable
final class LabelEditor {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    let mrKey: String
    private(set) var phase: Phase = .loading
    /// Every label in the MR's project, sorted by name.
    private(set) var available: [GitLabLabel] = []
    var query = ""
    /// Labels with a request in flight.
    private(set) var busy: Set<String> = []
    private(set) var error: String?

    private let service: CommandCenter

    init(mrKey: String, service: CommandCenter) {
        self.mrKey = mrKey
        self.service = service
    }

    private var mr: TrackedMR? { service.store.mergeRequest(forKey: mrKey) }

    var applied: Set<String> { Set(mr?.labels ?? []) }

    /// "Labels for payments/api!412".
    var title: String { mr.map { "Labels for \($0.reference)" } ?? "Labels" }

    /// Matching labels: the MR's own first, then the rest, each alphabetical. Case-insensitive search.
    var visible: [GitLabLabel] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = needle.isEmpty ? available : available.filter { $0.name.lowercased().contains(needle) }
        let applied = applied
        return matching.filter { applied.contains($0.name) } + matching.filter { !applied.contains($0.name) }
    }

    func load() async {
        guard let mr else { return }
        phase = .loading
        do {
            available = try await service.projectLabels(for: mr)
            phase = .loaded
        } catch {
            phase = .failed(CommandCenter.describeActionFailure(error))
        }
    }

    /// Adds the label if the MR doesn't have it, removes it if it does.
    func toggle(_ name: String) async {
        guard let mr, !busy.contains(name) else { return }
        busy.insert(name)
        defer { busy.remove(name) }
        let adding = !mr.labels.contains(name)
        error = await service.setLabel(name, on: mr, applied: adding)
    }
}
