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

    /// Waits up to `timeout` for the diff's scroll view to exist and lay out its content.
    private func waitForDiffScrollView(in window: NSWindow, timeout: Duration = .seconds(3)) async throws -> NSScrollView {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if let scroll = diffScrollView(in: window.contentView!), (scroll.documentView?.frame.height ?? 0) > 2000 {
                return scroll
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try #require(diffScrollView(in: window.contentView!), "The diff's scroll view never appeared")
    }

    /// Waits up to `timeout` for the diff's scroll offset to satisfy `condition`; returns the last offset.
    @discardableResult
    private func waitForOffset(in window: NSWindow, timeout: Duration = .seconds(3),
                               _ condition: (CGFloat) -> Bool) async throws -> CGFloat {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var offset: CGFloat = .nan
        while clock.now < deadline {
            if let scroll = diffScrollView(in: window.contentView!) {
                offset = scroll.contentView.bounds.origin.y
                if condition(offset) { return offset }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return offset
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
        let first = try await waitForDiffScrollView(in: window)
        first.contentView.scroll(to: NSPoint(x: 0, y: 2000))
        first.reflectScrolledClipView(first.contentView)
        let scrolled = try await waitForOffset(in: window) { $0 > 1000 }
        try #require(scrolled > 1000, "Precondition: the first file is scrolled down")

        shown.file = Self.longFile("Second.swift", index: 1)
        // Give a wrong (kept) offset time to show up before checking it isn't there.
        try await Task.sleep(for: .milliseconds(300))
        let offset = try await waitForOffset(in: window) { $0 < 1 }
        #expect(offset < 1, "The next file should start at the top, was at \(offset)")
    }

    @Test(arguments: [DiffLayout.unified, .sideBySide])
    func jumpingToALineInAnotherFileStillScrollsThere(layout: DiffLayout) async throws {
        let shown = Shown(Self.longFile("First.swift", index: 0))
        shown.layout = layout
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Host(shown: shown))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(500))

        let second = Self.longFile("Second.swift", index: 1)
        shown.scrollRequest = ScrollRequest(fileID: second.id, line: 250)
        shown.file = second
        let offset = try await waitForOffset(in: window) { $0 > 1000 }
        #expect(offset > 1000, "Should scroll down to line 250, was at \(offset)")
    }
}
