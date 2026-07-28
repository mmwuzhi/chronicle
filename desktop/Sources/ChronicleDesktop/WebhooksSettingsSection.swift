import Combine
import SwiftUI
import ChronicleDesktopCore

// MARK: - Webhooks

struct WebhooksSection: View {
    let clients: CaptureClients

    @ObservedObject private var localization = DesktopLocalization.shared

    @State private var rules: [WebhookRule] = []
    @State private var error = ""
    @State private var editing: EditTarget?
    @State private var hoverID: String?
    @State private var loaded = false

    struct EditTarget: Identifiable {
        let rule: WebhookRule?
        var id: String { rule?.id ?? "new" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Webhooks")).font(.headline)
                    Text(L("POST a templated payload to an external service when a capture matches."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if clients.webhook() != nil {
                    Button { editing = EditTarget(rule: nil) } label: {
                        Label(L("Add Rule"), systemImage: "plus")
                    }
                }
            }

            if clients.webhook() == nil {
                Text(L("Sign in to manage webhooks.")).font(.callout).foregroundStyle(.secondary)
            } else if !error.isEmpty {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            if rules.isEmpty && clients.webhook() != nil && loaded {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.up.forward.app").font(.title2).foregroundStyle(.tertiary)
                    Text(L("No rules yet")).foregroundStyle(.secondary)
                    Text(L("e.g. captures mentioning an amount go to a ledger service."))
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                ForEach(rules) { ruleRow($0) }
            }
        }
        .task { await reload() }
        .sheet(item: $editing) { target in
            WebhookEditor(clients: clients, rule: target.rule) { await reload() }
        }
        .onReceive(clients.session.$generation.dropFirst()) { _ in
            rules = []
            error = ""
            editing = nil
            hoverID = nil
            loaded = false
            if clients.webhook() != nil {
                Task { await reload() }
            }
        }
    }

    @ViewBuilder private func ruleRow(_ rule: WebhookRule) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { on in setEnabled(rule, on) },
            ))
            .toggleStyle(.switch).controlSize(.mini).labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name).foregroundStyle(rule.enabled ? .primary : .secondary)
                Text(summary(rule)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button { editing = EditTarget(rule: rule) } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help(L("Edit"))
                .opacity(hoverID == rule.id ? 1 : 0)
            Button { delete(rule) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help(L("Delete"))
                .opacity(hoverID == rule.id ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editing = EditTarget(rule: rule) }
        .onHover { hoverID = $0 ? rule.id : (hoverID == rule.id ? nil : hoverID) }
        .padding(.vertical, 8)
        Divider()
    }

    private func summary(_ rule: WebhookRule) -> String {
        var conds: [String] = []
        if !rule.keywords.isEmpty {
            conds.append(L("keywords") + " " + rule.keywords.joined(separator: ", "))
        }
        if let q = rule.semanticQuery, !q.isEmpty {
            conds.append(L("semantic") + " “\(q)” ≥ \(String(format: "%.2f", rule.semanticThreshold))")
        }
        let cond = conds.isEmpty ? L("every capture") : conds.joined(separator: " | ")
        let host = URL(string: rule.targetUrl)?.host ?? rule.targetUrl
        return "\(cond) → \(host)"
    }

    private func reload() async {
        let generation = clients.session.snapshot()
        guard let client = clients.webhook() else { loaded = true; return }
        do {
            let loadedRules = try await client.list()
            guard clients.session.isCurrent(generation) else { return }
            rules = loadedRules
            error = ""
        } catch let err {
            guard clients.session.isCurrent(generation) else { return }
            error = "\(err)"
        }
        if clients.session.isCurrent(generation) { loaded = true }
    }

    private func setEnabled(_ rule: WebhookRule, _ on: Bool) {
        let generation = clients.session.snapshot()
        guard let client = clients.webhook() else { return }
        var draft = WebhookDraft(rule)
        draft.enabled = on
        Task { @MainActor in
            do {
                let updated = try await client.update(id: rule.id, draft)
                guard clients.session.isCurrent(generation) else { return }
                if let i = rules.firstIndex(where: { $0.id == rule.id }) { rules[i] = updated }
            } catch let err {
                guard clients.session.isCurrent(generation) else { return }
                error = "\(err)"
            }
        }
    }

    private func delete(_ rule: WebhookRule) {
        let generation = clients.session.snapshot()
        guard let client = clients.webhook() else { return }
        Task { @MainActor in
            do {
                try await client.delete(id: rule.id)
                guard clients.session.isCurrent(generation) else { return }
                rules.removeAll { $0.id == rule.id }
            } catch let err {
                guard clients.session.isCurrent(generation) else { return }
                error = "\(err)"
            }
        }
    }
}

private struct WebhookEditor: View {
    let clients: CaptureClients
    let rule: WebhookRule?
    let onDone: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var localization = DesktopLocalization.shared
    @State private var draft: WebhookDraft
    @State private var keywordsText: String
    @State private var busy = false
    @State private var error = ""
    @State private var testResult: String?

    init(clients: CaptureClients, rule: WebhookRule?, onDone: @escaping () async -> Void) {
        self.clients = clients
        self.rule = rule
        self.onDone = onDone
        let d = rule.map(WebhookDraft.init) ?? WebhookDraft()
        _draft = State(initialValue: d)
        _keywordsText = State(initialValue: d.keywords.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(rule == nil ? L("New Webhook") : L("Edit Webhook")).font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    label(L("Name"))
                    WorkspaceField(prompt: L("Ledger"), text: $draft.name, compact: true)
                }
                GridRow {
                    label("URL")
                    WorkspaceField(prompt: "https://ledger.example/api",
                                   text: $draft.targetUrl, compact: true)
                }
                GridRow {
                    label(L("Keywords"))
                    WorkspaceField(prompt: L("comma-separated, any match fires; optional"),
                                   text: $keywordsText, compact: true)
                }
                GridRow {
                    label(L("Semantic"))
                    VStack(alignment: .leading, spacing: 4) {
                        WorkspaceField(
                            prompt: L("describe what to match; empty = no semantic match"),
                            text: Binding(
                                get: { draft.semanticQuery ?? "" },
                                set: { draft.semanticQuery = $0 }),
                            compact: true)
                        if !(draft.semanticQuery ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                            HStack(spacing: 8) {
                                Slider(value: $draft.semanticThreshold, in: 0.3...0.9, step: 0.05)
                                    .controlSize(.small)
                                Text(String(format: "≥ %.2f", draft.semanticThreshold))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    .frame(width: 52, alignment: .trailing)
                            }
                        }
                    }
                }
                GridRow {
                    label(L("Payload"))
                    VStack(alignment: .leading, spacing: 4) {
                        TextEditor(text: $draft.payloadTemplate)
                            .font(.callout.monospaced()).frame(height: 90)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                        Text(L("Placeholders: [capture.text] [capture.id] [capture.created_at]"))
                            .font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                    }
                }
            }

            if let testResult {
                Text(testResult).font(.caption).foregroundStyle(.secondary)
            }
            if !error.isEmpty {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            HStack {
                Button(L("Save & Test")) { Task { await save(thenTest: true) } }
                    .disabled(!valid || busy)
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Save")) { Task { await save(thenTest: false); if error.isEmpty { dismiss() } } }
                    .keyboardShortcut(.defaultAction).disabled(!valid || busy)
            }
        }
        .padding(16).frame(width: 540)
        .onReceive(clients.session.$generation.dropFirst()) { _ in
            busy = false
            error = ""
            testResult = nil
            dismiss()
        }
    }

    private func label(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).frame(width: 76, alignment: .trailing)
            .gridColumnAlignment(.trailing)
    }

    private var valid: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.targetUrl.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.payloadTemplate.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save(thenTest: Bool) async {
        let generation = clients.session.snapshot()
        guard let client = clients.webhook() else { error = L("Sign in to save webhooks."); return }
        busy = true; error = ""; testResult = nil
        draft.keywords = keywordsText
            .split(whereSeparator: { ",，".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        do {
            let saved: WebhookRule
            if let id = rule?.id {
                saved = try await client.update(id: id, draft)
            } else {
                saved = try await client.create(draft)
            }
            guard clients.session.isCurrent(generation) else { return }
            await onDone()
            guard clients.session.isCurrent(generation) else { return }
            if thenTest {
                testResult = await runTest(
                    client: client,
                    ruleID: saved.id,
                    generation: generation
                )
            }
        } catch let err {
            guard clients.session.isCurrent(generation) else { return }
            self.error = "\(err)"
        }
        if clients.session.isCurrent(generation) { busy = false }
    }

    // Score the saved rule against the user's most recent capture (no delivery).
    private func runTest(
        client: WebhookAPIClient,
        ruleID: String,
        generation: UInt64
    ) async -> String {
        guard let recall = clients.recall() else { return L("Sign in to test.") }
        do {
            let page = try await recall.recent(limit: 1)
            guard clients.session.isCurrent(generation) else { return "" }
            guard let latest = page.items.first else { return L("No captures yet to test against.") }
            let result = try await client.test(id: ruleID, captureId: latest.id)
            guard clients.session.isCurrent(generation) else { return "" }
            let score = result.score.map { String(format: "%.3f", $0) } ?? "n/a"
            return DesktopLocalization.shared.format(
                "Against your latest capture: %@ (score %@).",
                result.matched ? L("matched") : L("no match"), score
            )
        } catch {
            return DesktopLocalization.shared.format("Test failed: %@", error.localizedDescription)
        }
    }
}
