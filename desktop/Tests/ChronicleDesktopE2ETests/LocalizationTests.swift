import Foundation
import ServiceManagement
import XCTest

@testable import ChronicleDesktop

final class LocalizationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "LocalizationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = ""
        super.tearDown()
    }

    @MainActor
    func testExplicitLanguageOverridesSystemPreference() {
        let localization = DesktopLocalization(
            defaults: defaults,
            preferredLanguages: { ["zh-Hans"] }
        )

        XCTAssertEqual(localization["Settings"], "设置")
        localization.set(.english)
        XCTAssertEqual(localization["Settings"], "Settings")
        XCTAssertEqual(defaults.string(forKey: InterfaceLanguage.storageKey), "english")
    }

    @MainActor
    func testSystemLanguageAndMissingTranslationFallback() {
        let chinese = DesktopLocalization(
            defaults: defaults,
            preferredLanguages: { ["zh-Hans-CN", "en"] }
        )
        XCTAssertTrue(chinese.usesChinese)
        XCTAssertEqual(chinese["Unknown copy"], "Unknown copy")

        let english = DesktopLocalization(
            defaults: defaults,
            preferredLanguages: { ["ja-JP"] }
        )
        XCTAssertFalse(english.usesChinese)
        XCTAssertEqual(english.format("%d captures waiting to sync.", 3), "3 captures waiting to sync.")
    }

    @MainActor
    func testCaptureTimeFollowsSelectedLanguage() {
        let localization = DesktopLocalization.shared
        let previous = localization.language
        defer { localization.set(previous) }

        localization.set(.chinese)
        let chinese = CaptureTime.precise("2026-07-04T05:35:00.000Z")
        XCTAssertTrue(chinese.contains("2026年"))
        XCTAssertTrue(chinese.contains("月"))

        localization.set(.english)
        let english = CaptureTime.precise("2026-07-04T05:35:00.000Z")
        XCTAssertTrue(english.contains("2026"))
        XCTAssertFalse(english.contains("年"))
    }

    @MainActor
    func testLaunchAtLoginReflectsRegisteredAndApprovalStates() {
        XCTAssertTrue(SettingsView.launchAtLoginRequested(for: .enabled))
        XCTAssertTrue(SettingsView.launchAtLoginRequested(for: .requiresApproval))
        XCTAssertFalse(SettingsView.launchAtLoginRequested(for: .notRegistered))
        XCTAssertFalse(SettingsView.launchAtLoginRequested(for: .notFound))
    }
}
