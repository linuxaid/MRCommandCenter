import Foundation
import Observation
import SwiftUI

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

/// Width rules for the Changes file list, which the user resizes by dragging its edge.
/// The width is always a fixed frame, never a content-dependent minimum (see the AppKit
/// layout loop gotcha in PLAN.md).
enum FileListWidth {
    static let standard: CGFloat = 230
    static let minimum: CGFloat = 160
    static let maximum: CGFloat = 520
    /// The diff keeps at least this much room beside the list.
    static let minimumDiffWidth: CGFloat = 360
    /// One accessibility increment or decrement.
    static let step: CGFloat = 20

    /// The width to show for `width` (a stored preference or a drag in progress) when the
    /// Changes area is `available` wide.
    static func clamped(_ width: CGFloat, available: CGFloat) -> CGFloat {
        let width = width.isNaN ? standard : width
        let upper = max(minimum, min(maximum, available - minimumDiffWidth))
        return min(max(width, minimum), upper)
    }
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

    /// Moves the file selection up (negative) or down the list, stopping at either end.
    /// With nothing selected, down picks the first file and up the last.
    func moveFileSelection(by offset: Int) {
        guard let files = diff?.files, !files.isEmpty else { return }
        guard let index = files.firstIndex(where: { $0.id == selectedFileID }) else {
            selectedFileID = offset > 0 ? files.first?.id : files.last?.id
            return
        }
        selectedFileID = files[min(max(index + offset, 0), files.count - 1)].id
    }

    /// ↑/↓ in the Changes area. Returns false to leave the key alone: while a comment box is
    /// open (the caret should move) or a modifier is held (⌥⌘↑↓ steps the MR queue).
    /// Arrow keys always carry `.function` and `.numericPad`, so only real modifiers count.
    func handleArrow(by offset: Int, modifiers: EventModifiers, isComposing: Bool) -> Bool {
        let held = modifiers.intersection([.command, .option, .shift, .control])
        guard held.isEmpty, !isComposing, diff != nil else { return false }
        moveFileSelection(by: offset)
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
