import SwiftUI
import ChronicleDesktopCore

// A deliberately small resurfacing workspace. The server owns selection and
// deduplication; the desktop only presents today's two buckets in local time.
// There is no seen state, rating, streak, or review queue to maintain.
struct MainReviewPane: View {
    let clients: CaptureClients
    let sessionAvailable: Bool
    @ObservedObject private var localization = DesktopLocalization.shared

    @State private var onThisDay: [Capture] = []
    @State private var rediscover: [Capture] = []
    @State private var loaded = false
    @State private var refreshing = false
    @State private var signedIn = true
    @State private var error = ""
    @State private var pinTick = 0
    @State private var loadGeneration = 0

    private var isEmpty: Bool {
        loaded && onThisDay.isEmpty && rediscover.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !signedIn {
                signedOutState
            } else if !loaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isEmpty {
                Text(L("Nothing to revisit yet. Older captures will surface here over time."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                reviewList
            }
        }
        .padding(16)
        .task { await load() }
        .onChange(of: sessionAvailable) { available in
            loadGeneration &+= 1
            refreshing = false
            if available {
                loaded = false
                Task { await load() }
            } else {
                signedIn = false
                loaded = true
                onThisDay = []
                rediscover = []
                error = ""
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .chronicleMainShown)) { _ in
            Task { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .chronicleCapturesChanged)) { _ in
            Task { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .chroniclePinsChanged)) { _ in
            pinTick &+= 1
        }
        .onDisappear {
            loadGeneration &+= 1
            refreshing = false
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Review"))
                    .font(.headline)
                Text(L("Revisit what you captured before."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if refreshing && loaded {
                ProgressView().controlSize(.small)
            }
            if signedIn && loaded {
                Button { Task { await load() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(L("Refresh"))
                .accessibilityLabel(L("Refresh"))
                .disabled(refreshing)
            }
        }
    }

    private var signedOutState: some View {
        VStack(spacing: 10) {
            Text(L("Sign in to review your synced captures."))
                .foregroundStyle(.secondary)
            Button(L("Sign In")) { clients.openSignIn() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var reviewList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if !onThisDay.isEmpty {
                    sectionHeader(L("On this day"), count: onThisDay.count)
                    rows(onThisDay)
                }
                if !rediscover.isEmpty {
                    sectionHeader(L("Rediscover"), count: rediscover.count)
                    rows(rediscover)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 8)
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(String(count))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Color.primary.opacity(0.08)
                .frame(height: 1)
        }
        .padding(.top, 8)
    }

    private func rows(_ captures: [Capture]) -> some View {
        ForEach(captures) { capture in
            let row = RowItem(capture)
            CaptureRow(
                item: row,
                onOpen: { clients.openDetail(row) },
                onPin: { clients.togglePin(row) },
                isPinned: clients.isPinned(row.id),
                onBeginEdit: { clients.openDetail(row) },
            )
            .id("\(row.id)-\(pinTick)")
        }
    }

    @MainActor
    private func load() async {
        let generation = loadGeneration
        guard !refreshing else { return }
        guard let client = clients.recall() else {
            signedIn = false
            loaded = true
            error = ""
            return
        }
        signedIn = true
        refreshing = true
        defer {
            if generation == loadGeneration {
                refreshing = false
            }
        }
        do {
            let offset = -TimeZone.current.secondsFromGMT(for: Date()) / 60
            let response = try await client.reviewToday(timezoneOffsetMinutes: offset)
            guard generation == loadGeneration, sessionAvailable else { return }
            onThisDay = response.onThisDay
            rediscover = response.rediscover
            loaded = true
            error = ""
        } catch let loadError {
            guard generation == loadGeneration, sessionAvailable else { return }
            loaded = true
            error = describeCaptureError(loadError)
        }
    }
}
