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

    static let closedMessage = "This merge request is no longer open."

    /// Shows the labels from last time right away, then the fresh list from GitLab.
    func load() async {
        guard let mr else {
            phase = .failed(Self.closedMessage)
            return
        }
        if let cached = service.cachedProjectLabels(for: mr) {
            available = cached
            phase = .loaded
        } else {
            phase = .loading
        }
        do {
            available = try await service.projectLabels(for: mr)
            phase = .loaded
        } catch {
            if available.isEmpty {
                phase = .failed(CommandCenter.describeLabelFailure(error, changing: false))
            } else {
                self.error = CommandCenter.describeLabelFailure(error, changing: false)
            }
        }
    }

    /// Adds the label if the MR doesn't have it, removes it if it does.
    func toggle(_ name: String) async {
        guard let mr else {
            error = Self.closedMessage
            return
        }
        guard !busy.contains(name) else { return }
        busy.insert(name)
        defer { busy.remove(name) }
        let adding = !mr.labels.contains(name)
        error = await service.setLabel(name, on: mr, applied: adding)
    }

    /// Return in the search field: adds the best match. It never removes, so a stray Return
    /// can't take a label off, and does nothing until something is typed.
    func submit() async {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty,
              let match = visible.first(where: { !applied.contains($0.name) }) else { return }
        await toggle(match.name)
    }
}
