import ChronicleDesktopCore
import Testing

@Suite("Quick panel focus restoration")
struct QuickPanelFocusStateTests {
    @Test("records an external frontmost app and consumes it once")
    func recordsExternalFrontmostApp() {
        var state = QuickPanelFocusState()

        state.remember(frontmostApplicationProcessIdentifier: 10, currentApplicationProcessIdentifier: 20)

        #expect(state.consumeForRestore() == 10)
        #expect(state.consumeForRestore() == nil)
    }

    @Test("does not record Chronicle itself as the previous app")
    func ignoresCurrentApplication() {
        var state = QuickPanelFocusState()

        state.remember(frontmostApplicationProcessIdentifier: 20, currentApplicationProcessIdentifier: 20)

        #expect(state.consumeForRestore() == nil)
    }

    @Test("does not overwrite the original app while the panel is already open")
    func keepsOriginalApplicationUntilClose() {
        var state = QuickPanelFocusState()

        state.remember(frontmostApplicationProcessIdentifier: 10, currentApplicationProcessIdentifier: 20)
        state.remember(frontmostApplicationProcessIdentifier: 30, currentApplicationProcessIdentifier: 20)

        #expect(state.consumeForRestore() == 10)
    }

    @Test("discard drops focus restoration when the user chooses another app")
    func discardDropsRestorationTarget() {
        var state = QuickPanelFocusState()

        state.remember(frontmostApplicationProcessIdentifier: 10, currentApplicationProcessIdentifier: 20)
        state.discard()

        #expect(state.consumeForRestore() == nil)
    }
}
