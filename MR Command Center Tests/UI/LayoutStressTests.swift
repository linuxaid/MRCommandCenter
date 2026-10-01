import AppKit
import SwiftData
import SwiftUI
import Testing
@testable import MR_Command_Center

/// Regression test for an AppKit crash ("needing another Update Constraints in Window
/// pass") when the sidebar, detail, and inspector were all open and the window was
/// narrowed, or the inspector was opened in a narrow window. A hit crashes the test run.
@Suite(.serialized)
struct LayoutStressTests {
    @Test(arguments: DetailTab.allCases)
    func resizingWithEveryPanelOpenDoesNotLoop(tab: DetailTab) async throws {
        let model = AppModel.testing()
        await model.mergeRequests.refresh(.automatic)
        model.mergeRequests.selectedKey = model.mergeRequests.mergeRequests.first { $0.iid == 412 }?.key
        model.detailTab = tab
        model.isInspectorPresented = true

        let host = NSHostingView(rootView: RootView().environment(model).modelContainer(model.modelContainer))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(600))

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

        let minimum = window.contentLayoutRect.width
        #expect(minimum <= 700, "Window minimum should stay small enough for a laptop screen, was \(minimum)")
    }
}
