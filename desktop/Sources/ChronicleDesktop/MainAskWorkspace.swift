import SwiftUI
import ChronicleDesktopCore

/// The Ask tab's presentation. MainView owns request state and side effects;
/// this view only renders that state and forwards user intent.
struct MainAskWorkspace: View {
    let signedIn: Bool
    let busy: Bool
    let error: String
    let submittedQuestion: String
    let answer: String
    let sources: [AskSource]
    @Binding var query: String
    @Binding var focused: Bool
    @Binding var editorHeight: CGFloat
    let onAsk: () -> Void
    let onSignIn: () -> Void
    let onCopy: (String) -> Void

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        content
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
                }

                if submittedQuestion.isEmpty && answer.isEmpty && !busy {
                    if signedIn {
                        Text(L("Ask about anything you've captured."))
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    } else {
                        signInPrompt
                    }
                }
            }
            .frame(maxHeight: .infinity)

            if !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }

            composer
                .frame(maxWidth: 760)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 16)
    }

    @ViewBuilder private var content: some View {
        if !submittedQuestion.isEmpty {
            Text(L("Question"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(submittedQuestion)
                .font(.title3.weight(.medium))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider().padding(.vertical, 2)
        }

        if busy {
            ProgressView(L("Searching your captures…"))
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        } else if !answer.isEmpty {
            HStack {
                Spacer()
                Button { onCopy(answer) } label: {
                    Label(L("Copy"), systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text(answer)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !sources.isEmpty {
                Divider().padding(.vertical, 4)
                Text(L("Sources"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(sources) { source in
                    HStack(alignment: .top, spacing: 8) {
                        Text("[\(source.n)]")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.content)
                            Text(String(source.createdAt.prefix(10)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    Divider()
                }
            }
        }
    }

    private var signInPrompt: some View {
        VStack(spacing: 6) {
            Text(L("Ask works across your synced captures."))
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(L("Sign in below to use server-backed recall."))
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ModeTextEditor(
                text: $query,
                focused: $focused,
                placeholder: signedIn
                    ? L("Ask a question, e.g. what did I work on this week")
                    : L("Sign in to ask across your captures"),
                submitsOnEnter: true,
                onSubmit: onAsk,
                onCancel: { focused = false },
                onHeight: { editorHeight = min(max($0, 38), 120) },
                fontSize: 14,
            )
            .frame(height: editorHeight)
            .disabled(!signedIn || busy)

            HStack(spacing: 10) {
                Text(
                    signedIn
                        ? L("↩ Ask  ·  ⇧↩ New line")
                        : L("Sign in to ask across your captures")
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                if signedIn {
                    Button(action: onAsk) {
                        Image(systemName: "arrow.up")
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Color.chronicleOnAccent)
                    .clipShape(Circle())
                    .controlSize(.regular)
                    .disabled(
                        query.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty || busy
                    )
                    .help(L("Ask"))
                    .accessibilityLabel(L("Ask"))
                } else {
                    Button(L("Sign in"), action: onSignIn)
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(Color.chronicleOnAccent)
                        .controlSize(.regular)
                }
            }
        }
        .padding(10)
        .background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 12),
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.09), lineWidth: 1)
        }
        .accessibilityIdentifier("ask-composer")
        .animation(.easeOut(duration: 0.12), value: editorHeight)
    }
}
