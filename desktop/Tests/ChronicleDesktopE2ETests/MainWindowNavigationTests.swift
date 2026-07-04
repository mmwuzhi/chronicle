import Foundation
import Testing
@testable import ChronicleDesktop

@MainActor
@Suite("Main window navigation")
struct MainWindowNavigationTests {
    @Test("collapsing from the hovered titlebar button does not reopen on button exit")
    func collapseFromHoveredButtonIgnoresExitGrace() {
        let navigation = MainWindowNavigation(defaults: UserDefaults(suiteName: UUID().uuidString)!)

        navigation.tabsExpanded = true
        navigation.setTabsButtonHovering(true)
        #expect(navigation.tabsPeeking)

        navigation.toggleTabsExpanded()
        #expect(!navigation.tabsExpanded)
        #expect(!navigation.tabsPeeking)

        navigation.setTabsButtonHovering(false)
        #expect(!navigation.tabsPeeking)
    }
}
