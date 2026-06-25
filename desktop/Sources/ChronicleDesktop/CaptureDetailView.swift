import AppKit
import SwiftUI
import ChronicleDesktopCore

// A focused window for one capture: its full content plus the semantic "Related"
// suggestions the server serves at GET /captures/{id}/related. Tapping a related
// row navigates to it in place (with a Back stack), so the window doubles as a
// lightweight way to walk a chain of related memories. Read-only by design —
// editing, deleting and explicit linking live in the main window and the web app.
@MainActor
final class CaptureDetailModel: ObservableObject {
    @Published var capture: RowItem
    @Published var related: [RowItem] = []
    @Published var loading = false
    @Published var error = ""
    @Published private(set) var canGoBack = false

    private var history: [RowItem] = []
    private let clients: CaptureClients
    private var loadTask: Task<Void, Never>?

    init(capture: RowItem, clients: CaptureClients) {
        self.capture = capture
        self.clients = clients
    }

    var signedIn: Bool { clients.recall() != nil }

    // Navigate to a related capture, remembering where we came from.
    func open(_ row: RowItem) {
        guard row.id != capture.id else { return }
        history.append(capture)
        canGoBack = true
        capture = row
        reload()
    }

    func goBack() {
        guard let previous = history.popLast() else { return }
        canGoBack = !history.isEmpty
        capture = previous
        reload()
    }

    func reload() {
        loadTask?.cancel()
        related = []
        error = ""
        guard let client = clients.recall() else { return }
        let id = capture.id
        loading = true
        loadTask = Task { @MainActor in
            defer { loading = false }
            do {
                let items = try await client.related(id: id)
                guard !Task.isCancelled, id == capture.id else { return }
                related = items.map(RowItem.init)
            } catch {
                guard !Task.isCancelled, id == capture.id else { return }
                // Related is a non-essential surface — a failure shows the empty
                // state, never an alarming error, except for a clear auth lapse.
                if case CaptureAPIError.httpStatus(401) = error {
                    self.error = "Session expired — sign in again from Settings."
                }
            }
        }
    }
}

struct CaptureDetailView: View {
    @ObservedObject var model: CaptureDetailModel
    var onCopy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if model.canGoBack {
                    Button(action: model.goBack) {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Back")
                }
                Text("Capture").font(.headline)
                Spacer()
                Button { onCopy(model.capture.content) } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.capture.content.isEmpty ? "(media capture)" : model.capture.content)
                            .textSelection(.enabled)
                            .foregroundStyle(model.capture.content.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(CaptureTime.precise(model.capture.createdAt))
                            .font(.caption2).foregroundStyle(.secondary)
                    }

                    Divider()

                    Text("Related").font(.caption).foregroundStyle(.secondary)
                    relatedSection
                }
                .padding(.trailing, 8)
            }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 380)
        .onAppear { model.reload() }
    }

    @ViewBuilder private var relatedSection: some View {
        if !model.error.isEmpty {
            Text(model.error).foregroundStyle(.red).font(.caption)
        } else if model.loading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        } else if !model.signedIn {
            Text("Sign in to see related captures.")
                .foregroundStyle(.secondary).font(.caption)
        } else if model.related.isEmpty {
            Text("No related captures yet.")
                .foregroundStyle(.secondary).font(.caption)
        } else {
            ForEach(model.related) { row in
                CaptureRow(
                    item: row,
                    onCopy: { onCopy(row.content) },
                    onOpen: { model.open(row) },
                )
                Divider().opacity(0.5)
            }
        }
    }
}

@MainActor
final class CaptureDetailWindowController {
    private var window: NSWindow?
    private let clients: CaptureClients

    init(clients: CaptureClients) { self.clients = clients }

    func open(_ row: RowItem) {
        let model = CaptureDetailModel(capture: row, clients: clients)
        let view = CaptureDetailView(model: model, onCopy: Self.copy)
        let w = window ?? makeWindow()
        window = w
        w.contentView = NSHostingView(rootView: view)
        ScreenPlacement.centerOnActiveScreen(w)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false,
        )
        w.title = "Capture"
        w.center()
        w.setFrameAutosaveName("ChronicleCaptureDetailWindow")
        w.isReleasedWhenClosed = false
        w.collectionBehavior.insert(.moveToActiveSpace)
        return w
    }

    private static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
