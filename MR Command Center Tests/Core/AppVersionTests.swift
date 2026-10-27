import Foundation
import Testing
@testable import MR_Command_Center

struct AppVersionTests {
    @Test func readsTheShortVersion() {
        #expect(AppVersion.version(from: ["CFBundleShortVersionString": "26.10.27"]) == "26.10.27")
    }

    @Test func missingOrBlankIsNil() {
        #expect(AppVersion.version(from: nil) == nil)
        #expect(AppVersion.version(from: [:]) == nil)
        #expect(AppVersion.version(from: ["CFBundleShortVersionString": "  "]) == nil)
    }

    @Test func runningAppHasAVersion() {
        #expect(AppVersion.current?.isEmpty == false)
    }
}
