import AppKit
import Observation
import SwiftUI
import Testing
@testable import MR_Command_Center

/// Switching files (↑/↓ in Changes) must show the new file's diff from the top, not at the
/// previous file's scroll offset (#22).
@Suite(.serialized)
struct DiffScrollResetTests {
    @Observable
    final class Shown {
        var file: DiffFile
        var layout: DiffLayout = .unified
        var scrollRequest: ScrollRequest?
        init(_ file: DiffFile) { self.file = file }
    }

    private struct Host: View {
        let shown: Shown

        var body: some View {
            @Bindable var shown = shown
            FileDiffView(file: shown.file, threadCount: 0, scrollRequest: shown.scrollRequest,
                         layout: $shown.layout, isCollapsed: false,
                         expand: {}, openInBrowser: {})
                .environment(CommentsModel())
        }
    }

    static func longFile(_ name: String, index: Int) -> DiffFile {
        let lines = (1...300).map { "+let line\($0) = \($0)" }.joined(separator: "\n")
        let diff = GitLabDiff(oldPath: name, newPath: name, diff: "@@ -0,0 +1,300 @@\n" + lines,
                              newFile: true, renamedFile: false, deletedFile: false)
        return DiffFile(diff, index: index)
    }

    /// The diff's scroll view (the one with the tallest content).
    private func diffScrollView(in view: NSView) -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    @Test(arguments: [DiffLayout.unified, .sideBySide])
    func nextFileStartsAtTheTop(layout: DiffLayout) async throws {
        let shown = Shown(Self.longFile("First.swift", index: 0))
        shown.layout = layout
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Host(shown: shown))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(500))

        let first = try #require(diffScrollView(in: window.contentView!))
        first.contentView.scroll(to: NSPoint(x: 0, y: 2000))
        first.reflectScrolledClipView(first.contentView)
        try await Task.sleep(for: .milliseconds(200))
        #expect(first.contentView.bounds.origin.y > 1000, "Precondition: the first file is scrolled down")

        shown.file = Self.longFile("Second.swift", index: 1)
        try await Task.sleep(for: .milliseconds(500))

        let second = try #require(diffScrollView(in: window.contentView!))
        #expect(second.contentView.bounds.origin.y < 1, "The next file should start at the top, was at \(second.contentView.bounds.origin.y)")
    }

    @Test func jumpingToALineInAnotherFileStillScrollsThere() async throws {
        let shown = Shown(Self.longFile("First.swift", index: 0))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Host(shown: shown))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(500))

        let second = Self.longFile("Second.swift", index: 1)
        shown.scrollRequest = ScrollRequest(fileID: second.id, line: 250)
        shown.file = second
        try await Task.sleep(for: .milliseconds(1000))

        let scroll = try #require(diffScrollView(in: window.contentView!))
        #expect(scroll.contentView.bounds.origin.y > 1000, "Should scroll down to line 250, was at \(scroll.contentView.bounds.origin.y)")
    }
}
