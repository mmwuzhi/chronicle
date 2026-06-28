import SwiftUI
import ChronicleDesktopCore

// The inline "+ Link" drawer inside the capture detail window: search the user's
// captures (or pick from the semantic suggestions already on screen) and tap one
// to link it to the capture in view. It lives inside the window rather than in a
// popover so it can never drift off-screen. Stateless about links themselves — it
// reports a pick and the model owns the add + re-sync.
struct LinkPickerView: View {
    // Default candidates shown before searching (the detail window's "Related"
    // list, already filtered of self + existing links by the server).
    let suggestions: [RowItem]
    // Returns search candidates for a query (model.linkCandidates, which excludes
    // this capture and everything already linked).
    var search: @MainActor (String) async -> [RowItem]
    var onPick: (RowItem) -> Void

    @State private var query = ""
    @State private var results: [RowItem] = []
    @State private var searching = false
    @State private var didSearch = false
    // Monotonic id of the latest search; a slower earlier search whose id no longer
    // matches drops its result instead of clobbering a newer query's results.
    @State private var searchGen = 0

    private var hasQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var shown: [RowItem] { hasQuery ? results : suggestions }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WorkspaceField(prompt: "Search captures to link…", text: $query,
                           compact: true, onSubmit: runSearch)

            if searching {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            } else if shown.isEmpty {
                Text(emptyMessage).font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(shown) { row in
                    Button { onPick(row) } label: { rowLabel(row) }
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private var emptyMessage: String {
        if !hasQuery { return "Search to find captures to link." }
        return didSearch ? "No matches." : "Press return to search."
    }

    private func rowLabel(_ row: RowItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "plus.circle")
                .foregroundStyle(.secondary).font(.caption).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.content.isEmpty ? "(media capture)" : row.content)
                    .lineLimit(2).foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(CaptureTime.display(row.createdAt))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 3)
    }

    private func runSearch() {
        searchGen += 1
        let gen = searchGen
        let q = query
        searching = true
        Task { @MainActor in
            let found = await search(q)
            guard gen == searchGen else { return } // a newer search superseded this one
            results = found
            didSearch = true
            searching = false
        }
    }
}
