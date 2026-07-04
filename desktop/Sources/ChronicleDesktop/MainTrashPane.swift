import SwiftUI
import ChronicleDesktopCore

// Trash mode content, extracted from MainView: soft-deleted captures with an
// instant keyword filter, restore, per-row permanent delete, and Empty Trash.
// Self-contained — owns its state, loads on mount, and reloads on main-window
// reshow and on capture changes posted by other surfaces.
struct MainTrashPane: View {
    let clients: CaptureClients
    // MainView's capture-event token, shared so posts from trash actions are
    // recognised as "own" by every surface in this window and don't trigger a
    // stomping reload over the removal animations.
    let captureEventToken: NSObject

    // Trash: soft-deleted captures, filtered instantly on the loaded list.
    @State private var trash: [Capture] = []
    @State private var trashQuery = ""
    @State private var confirmingEmptyTrash = false
    // Set to the capture id awaiting a permanent-delete confirmation (irreversible).
    @State private var pendingPermanentDeleteId: String?
    // Distinguishes "not loaded yet" from "loaded and empty" so a fresh mount
    // doesn't flash the empty placeholder before the first fetch returns.
    @State private var loaded = false
    @State private var error = ""

    var body: some View {
        VStack(spacing: 12) {
            header

            if !error.isEmpty {
                Text(error).foregroundStyle(.red).font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollView {
                list.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
            }
        }
        .padding(16)
        // Per-row permanent delete is irreversible; confirm before hard-deleting,
        // matching Empty Trash and the web flow.
        .confirmationDialog(
            "Delete this capture permanently? This can't be undone.",
            isPresented: Binding(
                get: { pendingPermanentDeleteId != nil },
                set: { if !$0 { pendingPermanentDeleteId = nil } },
            ),
            presenting: pendingPermanentDeleteId,
        ) { id in
            Button("Delete Permanently", role: .destructive) { permanentlyDelete(id) }
            Button("Cancel", role: .cancel) {}
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .chronicleMainShown)) { _ in
            Task { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .chronicleCapturesChanged)) { note in
            guard (note.object as? NSObject) !== captureEventToken else { return }
            Task { await load() }
        }
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: 10) {
            WorkspaceField(prompt: "Filter trash", text: $trashQuery, disabled: false)
            if !trash.isEmpty {
                Button("Empty", role: .destructive) { confirmingEmptyTrash = true }
                    .buttonStyle(.borderless).font(.caption).foregroundStyle(.red)
                    .confirmationDialog(
                        "Permanently delete all \(trash.count) captures in the trash?",
                        isPresented: $confirmingEmptyTrash, titleVisibility: .visible,
                    ) {
                        Button("Empty Trash", role: .destructive) { emptyTrash() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This can't be undone.")
                    }
            }
        }
    }

    // Instant keyword filter over the loaded trash — a "find the one I deleted"
    // surface, plain substring, never semantic (so a trashed row can't leak into a
    // recall path). Empty query shows everything.
    private var filteredTrash: [Capture] {
        let q = trashQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return trash }
        return trash.filter { $0.content.localizedCaseInsensitiveContains(q) }
    }

    @ViewBuilder private var list: some View {
        let items = filteredTrash
        if items.isEmpty {
            if loaded {
                Text(trashQuery.isEmpty ? "Trash is empty." : "No trashed captures match.")
                    .foregroundStyle(.secondary).padding(.top, 8)
            }
        } else {
            ForEach(items) { row($0) }
        }
    }

    @ViewBuilder private func row(_ capture: Capture) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if capture.mediaType != "text" && capture.content.isEmpty {
                Image(systemName: capture.mediaType == "audio" ? "waveform" : "photo")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 3)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(capture.content.isEmpty ? "(media capture)" : capture.content)
                    .textSelection(.enabled).lineLimit(6)
                    .foregroundStyle(capture.content.isEmpty ? .secondary : .primary)
                HStack(spacing: 8) {
                    Text("Deleted \(CaptureTime.display(capture.deletedAt ?? capture.createdAt))")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button { restore(capture.id) } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless).font(.caption)
                    Button(role: .destructive) { pendingPermanentDeleteId = capture.id } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.borderless).font(.caption).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        Divider().opacity(0.5)
    }

    private func load() async {
        guard let client = clients.recall() else {
            trash = []
            loaded = true
            return
        }
        do {
            let items = try await client.trash()
            withAnimation(.easeInOut(duration: 0.2)) { trash = items }
            error = ""
        } catch let err { error = describeCaptureError(err) }
        loaded = true
    }

    // Restore returns the capture (with its links + reminder) to browse. Drop it
    // from the local trash list and let the next browse load pick it back up.
    private func restore(_ id: String) {
        guard let client = clients.recall() else { return }
        Task { @MainActor in
            do {
                try await client.restore(id: id)
                CaptureEvents.postChanged(from: captureEventToken)
                withAnimation(.easeInOut(duration: 0.2)) { trash.removeAll { $0.id == id } }
            } catch let err { error = describeCaptureError(err) }
        }
    }

    // Permanent delete is irreversible; the trash is itself the undo buffer, so
    // there's no toast — just drop the row.
    private func permanentlyDelete(_ id: String) {
        guard let client = clients.recall() else { return }
        Task { @MainActor in
            do {
                try await client.permanentDelete(id: id)
                clients.localDelete(id)
                CaptureEvents.postChanged(from: captureEventToken)
                withAnimation(.easeInOut(duration: 0.2)) { trash.removeAll { $0.id == id } }
            } catch let err { error = describeCaptureError(err) }
        }
    }

    private func emptyTrash() {
        guard let client = clients.recall() else { return }
        let ids = trash.map(\.id)
        Task { @MainActor in
            do {
                _ = try await client.emptyTrash()
                for id in ids { clients.localDelete(id) }
                CaptureEvents.postChanged(from: captureEventToken)
                withAnimation(.easeInOut(duration: 0.2)) { trash = [] }
            } catch let err { error = describeCaptureError(err) }
        }
    }
}
