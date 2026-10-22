import AppKit
import Foundation
import Testing
@testable import MR_Command_Center

/// The app ships the layered `AppIcon.icon` (Icon Composer), not the generic app icon.
/// The test target is hosted, so `Bundle.main` is the app.
struct AppIconTests {
    @Test func bundleNamesTheAppIcon() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String == "AppIcon")
    }

    @Test func compiledIconIsInTheBundle() throws {
        // actool writes an .icns fallback next to the layered icon in Assets.car.
        let icns = try #require(Bundle.main.url(forResource: "AppIcon", withExtension: "icns"))
        let image = try #require(NSImage(contentsOf: icns))
        #expect(image.size.width >= 128)
        #expect(Bundle.main.url(forResource: "Assets", withExtension: "car") != nil)
    }
}
