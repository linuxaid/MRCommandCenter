import AppKit
import SwiftData
import SwiftUI
import Testing
@testable import MR_Command_Center

/// Regression tests for an AppKit crash ("needing another Update Constraints in Window
/// pass") when panels were open and the window was narrowed, or the inspector was opened
/// in a narrow window. A hit crashes the test run.
@Suite(.serialized)
struct LayoutStressTests {
    @Test(arguments: [Destination.briefing, .lane(.yourMove), .activity, .rules])
    func resizingTheCommandCenterDoesNotLoop(destination: Destination) async throws {
        let model = AppModel.testing()
        await model.refresh(.automatic)
        model.mergeRequests.selectedKey = model.mergeRequests.trackedMergeRequests.first { $0.iid == 412 }?.key
        if destination == .rules {
            model.commandCenter.addRule()
        }
        model.commandCenter.destination = destination

        let window = try await host(RootView().environment(model).modelContainer(model.modelContainer), width: 1400)
        defer { window.orderOut(nil) }

        for width in [1100, 900, 700, 500, 1400] {
            window.setContentSize(NSSize(width: width, height: 800))
            try await Task.sleep(for: .milliseconds(150))
        }
        // Ask for something tiny; AppKit stops at the layout's minimum.
        window.setContentSize(NSSize(width: 300, height: 800))
        try await Task.sleep(for: .milliseconds(300))
        let minimum = window.contentLayoutRect.width
        #expect(minimum <= 1000, "Window minimum should fit a laptop screen, was \(minimum)")
    }

    @Test(arguments: DetailTab.allCases)
    func resizingReviewModeWithTheInspectorOpenDoesNotLoop(tab: DetailTab) async throws {
        let model = AppModel.testing()
        await model.mergeRequests.refresh(.automatic)
        let mr = try #require(model.mergeRequests.trackedMergeRequests.first { $0.iid == 412 })
        model.review(mr)
        model.detailTab = tab
        model.isInspectorPresented = true

        let window = try await host(RootView().environment(model).modelContainer(model.modelContainer), width: 1400)
        defer { window.orderOut(nil) }

        for width in [1100, 900, 700, 500, 1400] {
            window.setContentSize(NSSize(width: width, height: 800))
            try await Task.sleep(for: .milliseconds(150))
        }
        // Open the inspector while the window is at its narrowest.
        model.isInspectorPresented = false
        window.setContentSize(NSSize(width: 500, height: 800))
        try await Task.sleep(for: .milliseconds(150))
        model.isInspectorPresented = true
        try await Task.sleep(for: .milliseconds(300))
        window.setContentSize(NSSize(width: 300, height: 800))
        try await Task.sleep(for: .milliseconds(300))

        let minimum = window.contentLayoutRect.width
        #expect(minimum <= 1000, "Window minimum should fit a laptop screen, was \(minimum)")
    }

    private func host(_ view: some View, width: CGFloat) async throws -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(600))
        return window
    }
}
