import Foundation
import Observation

enum DiffLayout: String, CaseIterable, Identifiable {
    case unified, sideBySide

    var id: Self { self }
    var title: String { self == .unified ? "Unified" : "Side by Side" }
}

/// Ask a diff view to scroll to (and briefly highlight) a new-side line.
struct ScrollRequest: Equatable {
    let id = UUID()
    let fileID: DiffFile.ID
    let line: Int
}

/// Loads one MR's diff and tracks file selection and expansion.
@Observable
final class ChangesModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded(MRDiff)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    var selectedFileID: DiffFile.ID?
    /// Large or collapsed files the user chose to show.
    var expandedFileIDs: Set<DiffFile.ID> = []
    var scrollRequest: ScrollRequest?

    /// Selects, expands, and scrolls to a file's line. Returns false if the file isn't in the diff.
    @discardableResult
    func reveal(path: String, line: Int) -> Bool {
        guard let file = diff?.files.first(where: { $0.path == path || $0.oldPath == path }) else { return false }
        selectedFileID = file.id
        expandedFileIDs.insert(file.id)
        scrollRequest = ScrollRequest(fileID: file.id, line: line)
        return true
    }

    var diff: MRDiff? {
        if case .loaded(let diff) = phase { return diff }
        return nil
    }

    var selectedFile: DiffFile? {
        diff?.files.first { $0.id == selectedFileID }
    }

    func load(_ mr: TrackedMR, using service: DiffService, forceRefresh: Bool = false) async {
        if diff == nil { phase = .loading }
        do {
            let diff = try await service.diff(for: mr, forceRefresh: forceRefresh)
            phase = .loaded(diff)
            if selectedFileID == nil || !diff.files.contains(where: { $0.id == selectedFileID }) {
                selectedFileID = diff.files.first?.id
            }
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func isCollapsed(_ file: DiffFile, threshold: Int) -> Bool {
        guard !expandedFileIDs.contains(file.id) else { return false }
        return file.isGenerated || file.isCollapsedByGitLab || file.lineCount > threshold
    }
}
