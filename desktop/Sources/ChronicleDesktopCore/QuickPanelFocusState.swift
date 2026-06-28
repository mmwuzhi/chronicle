import Darwin

package struct QuickPanelFocusState: Equatable {
    private var previousApplicationProcessIdentifier: pid_t?

    package init() {}

    package mutating func remember(
        frontmostApplicationProcessIdentifier: pid_t?,
        currentApplicationProcessIdentifier: pid_t
    ) {
        guard previousApplicationProcessIdentifier == nil,
              let frontmostApplicationProcessIdentifier,
              frontmostApplicationProcessIdentifier != currentApplicationProcessIdentifier else { return }
        previousApplicationProcessIdentifier = frontmostApplicationProcessIdentifier
    }

    package mutating func consumeForRestore() -> pid_t? {
        defer { previousApplicationProcessIdentifier = nil }
        return previousApplicationProcessIdentifier
    }

    package mutating func discard() {
        previousApplicationProcessIdentifier = nil
    }
}
