import Foundation
import ChronicleDesktopCore

enum MarkdownTaskMutationResult {
    case unchanged
    case conflict(currentRawText: String)
    case updatedLocally(rawText: String)
    case updatedRemotely(Capture)
}

/// Applies one source-preserving Markdown task change against the freshest
/// authoritative Capture text. UI surfaces remain responsible for projecting
/// the result into their own view state.
@MainActor
struct MarkdownTaskMutationCoordinator {
    let clients: CaptureClients

    func setCompletion(
        captureID: String,
        displayedRawText: String,
        lineIndex: Int,
        completedOn: String?,
        sessionGeneration: UInt64,
        targetIsCurrent: () -> Bool
    ) async throws -> MarkdownTaskMutationResult? {
        func mutationIsCurrent() -> Bool {
            !Task.isCancelled
                && clients.session.isCurrent(sessionGeneration)
                && targetIsCurrent()
        }

        guard mutationIsCurrent() else { return nil }

        let initialLocal = try clients.localTaskSource(captureID).get()
        let client = clients.recall()
        let currentRawText: String
        let writesLocally: Bool

        if let initialLocal, initialLocal.isAuthoritative || client == nil {
            currentRawText = initialLocal.rawText
            writesLocally = true
        } else {
            guard let client else {
                throw MarkdownTaskMutationError.sourceUnavailable
            }
            let current = try await client.capture(id: captureID)
            guard mutationIsCurrent(), current.mediaType == "text",
                  let remoteRawText = current.rawText
            else { return nil }

            let latestLocal = try clients.localTaskSource(captureID).get()
            if let latestLocal, latestLocal.isAuthoritative {
                currentRawText = latestLocal.rawText
                writesLocally = true
            } else {
                currentRawText = remoteRawText
                writesLocally = initialLocal != nil
            }
        }

        guard let next = MarkdownTaskDocument.settingCompletion(
            in: currentRawText,
            matchingTaskIn: displayedRawText,
            lineIndex: lineIndex,
            completedOn: completedOn
        ) else {
            return .conflict(currentRawText: currentRawText)
        }
        guard next != currentRawText else { return .unchanged }

        if writesLocally {
            guard clients.localSetText(captureID, next) else {
                throw MarkdownTaskMutationError.sourceUnavailable
            }
            return .updatedLocally(rawText: next)
        }

        guard let client else {
            throw MarkdownTaskMutationError.sourceUnavailable
        }
        let updated = try await client.update(id: captureID, rawText: next)
        guard mutationIsCurrent() else { return nil }
        return .updatedRemotely(updated)
    }
}
