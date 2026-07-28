import AppKit
import Combine
import ChronicleDesktopCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum CaptureDraftFileKind: Equatable {
    case directMedia
    case cloudAttachment
}

struct CaptureDraftFile: Equatable {
    let url: URL
    let name: String
    let mimeType: String
    let sizeBytes: Int
    let identity: CaptureFileIdentity
    let kind: CaptureDraftFileKind
    let durationSeconds: Int?
    let temporary: Bool
}

enum CaptureDraftFileError: Error {
    case fileTooLarge
    case unsupportedFile
}

private let maximumDirectImagePixels = 50_000_000

func captureDraftFile(
    at url: URL,
    durationSeconds: Int? = nil,
    temporary: Bool = false
) throws -> CaptureDraftFile {
    let accessing = url.startAccessingSecurityScopedResource()
    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
    let snapshot: CaptureFileSnapshot
    do {
        snapshot = try inspectCaptureFile(at: url, maxBytes: googleDriveUploadMaxBytes)
    } catch SecureCaptureFileError.fileTooLarge {
        throw CaptureDraftFileError.fileTooLarge
    } catch {
        throw CaptureDraftFileError.unsupportedFile
    }
    let type = UTType(filenameExtension: url.pathExtension)
    let genericMimeType = type?.preferredMIMEType ?? "application/octet-stream"
    let directMimeType = snapshot.mediaMimeType.flatMap { mime -> String? in
        guard mime.hasPrefix("image/") else { return mime }
        guard captureImagePixelCount(at: url).map({ $0 <= maximumDirectImagePixels }) == true else {
            return nil
        }
        return mime
    }
    let size = snapshot.identity.sizeBytes
    let direct = directMimeType != nil && size <= directCaptureUploadMaxBytes
    return CaptureDraftFile(
        url: url,
        name: url.lastPathComponent,
        mimeType: directMimeType ?? genericMimeType,
        sizeBytes: size,
        identity: snapshot.identity,
        kind: direct ? .directMedia : .cloudAttachment,
        durationSeconds: durationSeconds,
        temporary: temporary
    )
}

private func captureImagePixelCount(at url: URL) -> Int? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int,
          width > 0,
          height > 0,
          width <= Int.max / height
    else {
        return nil
    }
    return width * height
}

@MainActor
final class MainCaptureSheetModel: ObservableObject {
    @Published var text = ""
    @Published var editorHeight: CGFloat = 120
    @Published var focused = false
    @Published var file: CaptureDraftFile?
    @Published var remindOn = false
    @Published var remindAt = Date().addingTimeInterval(3600)
    @Published var keepVisible = false
    @Published var busy = false
    @Published var error = ""
    @Published private(set) var operationId = UUID().uuidString
    let recorder = CaptureAudioRecorder()
    private(set) var activeSaveTask: Task<Void, Never>?

    init() {
        recorder.onMaximumDuration = { [weak self] recording in
            self?.selectFile(
                recording.url,
                durationSeconds: recording.durationSeconds,
                temporary: true
            )
        }
    }

    var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || file != nil
    }

    func selectFile(_ url: URL, durationSeconds: Int? = nil, temporary: Bool = false) {
        do {
            let next = try captureDraftFile(
                at: url,
                durationSeconds: durationSeconds,
                temporary: temporary
            )
            discardTemporaryFile()
            file = next
            error = ""
        } catch CaptureDraftFileError.fileTooLarge {
            error = L("This file is too large.")
        } catch {
            self.error = L("We couldn't read that file.")
        }
    }

    func removeFile() {
        discardTemporaryFile()
        file = nil
    }

    func stopRecordingAndSelect() {
        guard let recording = recorder.stop() else { return }
        selectFile(
            recording.url,
            durationSeconds: recording.durationSeconds,
            temporary: true
        )
    }

    func resetAfterSave() {
        discardTemporaryFile()
        text = ""
        editorHeight = 120
        focused = false
        file = nil
        remindOn = false
        remindAt = Date().addingTimeInterval(3600)
        keepVisible = false
        busy = false
        error = ""
        operationId = UUID().uuidString
        activeSaveTask = nil
    }

    func prepareToDismiss() {
        if recorder.recording { recorder.cancel() }
        focused = false
    }

    func setActiveSaveTask(_ task: Task<Void, Never>) {
        activeSaveTask?.cancel()
        activeSaveTask = task
    }

    func finishSaveTask() {
        activeSaveTask = nil
    }

    func discardDraft() {
        activeSaveTask?.cancel()
        activeSaveTask = nil
        if recorder.recording { recorder.cancel() }
        discardTemporaryFile()
        text = ""
        file = nil
        busy = false
        error = ""
        operationId = UUID().uuidString
    }

    private func discardTemporaryFile() {
        guard let file, file.temporary else { return }
        try? FileManager.default.removeItem(at: file.url)
    }
}

struct MainCaptureLaunchButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(MainCaptureLaunchButtonStyle())
        .help(L("New Capture") + "  ⌘N")
        .accessibilityLabel(L("New Capture"))
        .accessibilityIdentifier("main-capture-launch")
    }
}

private struct MainCaptureLaunchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.chronicleOnAccent)
            .background(Color.primary.opacity(configuration.isPressed ? 0.76 : 0.92), in: Circle())
            .shadow(color: .black.opacity(0.16), radius: 4, y: 2)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct MainCaptureSheet: View {
    @ObservedObject var model: MainCaptureSheetModel
    let clients: CaptureClients
    let signedIn: Bool
    let onSaved: (RowItem) -> Void
    let onRequestSignIn: () -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var localization = DesktopLocalization.shared
    @State private var dropTargeted = false

    private var trimmedText: String {
        model.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var offersTodoSuggestion: Bool {
        CaptureTodoTag.offersSuggestion(for: model.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            composer
            if let file = model.file {
                selectedFile(file)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }
            if offersTodoSuggestion {
                todoSuggestion
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
            }
            if model.remindOn {
                reminderRow
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
            }
            footer
        }
        .frame(width: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(shortcutButton)
        .onAppear {
            DispatchQueue.main.async { model.focused = true }
        }
        .onDisappear { model.prepareToDismiss() }
        .onReceive(clients.session.$generation.dropFirst()) { _ in
            model.discardDraft()
            dismiss()
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted) { providers in
            acceptDrop(providers)
        }
    }

    private var header: some View {
        HStack {
            Text(L("New Capture"))
                .font(.headline)
            Spacer()
            Button { close() } label: {
                Image(systemName: "xmark")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(model.busy ? L("Cancel") : L("Close"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var composer: some View {
        ModeTextEditor(
            text: $model.text,
            focused: $model.focused,
            placeholder: L("Capture a thought…"),
            submitsOnEnter: false,
            onSubmit: save,
            onCancel: close,
            onHeight: { height in
                model.editorHeight = min(max(height, 120), 220)
            },
            fontSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
            hasCompletion: offersTodoSuggestion,
            onComplete: completeTodoSuggestion,
            onPasteAttachment: { url, temporary in
                model.selectFile(url, temporary: temporary)
            },
            onPasteAttachmentError: {
                model.error = L("This image is too large to paste.")
            }
        )
        .frame(height: model.editorHeight)
        .padding(.horizontal, 15)
        .padding(.vertical, 14)
        .background(
            dropTargeted ? Color.primary.opacity(0.05) : Color.clear
        )
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [5]))
                    .padding(8)
            }
        }
    }

    private func selectedFile(_ file: CaptureDraftFile) -> some View {
        HStack(spacing: 10) {
            filePreview(file)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(fileSubtitle(file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button(L("Quick Look")) {
                CaptureFilePreview.shared.show(file.url)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            Button { model.removeFile() } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L("Remove attachment"))
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func filePreview(_ file: CaptureDraftFile) -> some View {
        if file.mimeType.hasPrefix("image/"), let image = CaptureFilePreview.thumbnail(for: file.url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                .resizable()
                .frame(width: 32, height: 32)
                .padding(3)
        }
    }

    private var todoSuggestion: some View {
        Button(action: completeTodoSuggestion) {
            HStack(spacing: 8) {
                TodoFacetChip(state: .open)
                Text(L("Mark this capture as a todo"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(L("Tab"))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private var reminderRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell")
                .foregroundStyle(.secondary)
            DatePicker("", selection: $model.remindAt, in: Date()...)
                .labelsHidden()
                .datePickerStyle(.field)
                .controlSize(.small)
            Spacer()
            Toggle(L("Keep visible"), isOn: $model.keepVisible)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.error.isEmpty {
                Text(model.error)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if model.file != nil && !signedIn {
                HStack(spacing: 6) {
                    Text(L("Sign in to add files."))
                        .foregroundStyle(.secondary)
                    Button(L("Sign in"), action: signIn)
                        .buttonStyle(.link)
                }
                .font(.caption)
            }
            HStack(spacing: 8) {
                Button { chooseFile() } label: {
                    Label(L("Add file"), systemImage: "paperclip")
                }
                .buttonStyle(CaptureSheetToolButtonStyle())
                .disabled(model.busy || model.recorder.recording)

                Button { toggleRecording() } label: {
                    Label(
                        model.recorder.recording
                            ? L("Stop") + "  " + recordingTime
                            : L("Record"),
                        systemImage: model.recorder.recording ? "stop.fill" : "mic"
                    )
                }
                .buttonStyle(CaptureSheetToolButtonStyle(active: model.recorder.recording))
                .disabled(model.busy)

                Button { model.remindOn.toggle() } label: {
                    Label(L("Reminder"), systemImage: model.remindOn ? "bell.fill" : "bell")
                }
                .buttonStyle(CaptureSheetToolButtonStyle(active: model.remindOn))
                .disabled(model.busy)

                Spacer()

                if model.busy {
                    ProgressView()
                        .controlSize(.small)
                    Text(L("Saving…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(L("Save"), action: save)
                    .buttonStyle(CaptureDraftButtonStyle(kind: .primary))
                    .disabled(
                        !model.canSave
                            || model.busy
                            || model.recorder.recording
                            || (model.file != nil && !signedIn)
                    )
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var shortcutButton: some View {
        Button("") { save() }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.plain)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private var recordingTime: String {
        String(format: "%d:%02d / 5:00", model.recorder.seconds / 60, model.recorder.seconds % 60)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.selectFile(url)
        }
    }

    private func toggleRecording() {
        if model.recorder.recording {
            model.stopRecordingAndSelect()
            return
        }
        Task { @MainActor in
            do {
                try await model.recorder.start()
                model.error = ""
            } catch {
                model.error = L("Microphone access is required to record audio.")
            }
        }
    }

    private func save() {
        guard model.canSave, !model.busy, !model.recorder.recording else { return }
        model.busy = true
        model.error = ""
        let reminder = model.remindOn ? model.remindAt : nil
        let remindHide = model.remindOn ? !model.keepVisible : nil
        if let file = model.file {
            let generation = clients.session.snapshot()
            let operationId = model.operationId
            let task = Task { @MainActor in
                defer { model.finishSaveTask() }
                do {
                    let row: RowItem
                    switch file.kind {
                    case .directMedia:
                        let data = try await readStableDirectMedia(file)
                        try Task.checkCancellation()
                        row = try await clients.uploadMedia(
                            CaptureMediaUpload(
                                operationId: operationId,
                                data: data,
                                filename: file.name,
                                mimeType: file.mimeType,
                                text: trimmedText,
                                durationSeconds: file.durationSeconds,
                                remindAt: reminder,
                                remindHide: remindHide
                            )
                        )
                    case .cloudAttachment:
                        let stagedURL = try await stageStableFile(file)
                        defer { removeStagedCaptureFile(stagedURL) }
                        try Task.checkCancellation()
                        row = try await clients.attachFile(
                            CloudCaptureFileUpload(
                                operationId: operationId,
                                fileURL: stagedURL,
                                sizeBytes: file.sizeBytes,
                                filename: file.name,
                                mimeType: file.mimeType
                            ),
                            trimmedText,
                            reminder,
                            remindHide
                        )
                    }
                    guard clients.session.isCurrent(generation) else {
                        throw CancellationError()
                    }
                    finish(row)
                } catch is CancellationError {
                    model.busy = false
                } catch {
                    model.busy = false
                    model.error = captureSheetError(error)
                }
            }
            model.setActiveSaveTask(task)
            return
        }
        switch attemptTextSave() {
        case .success(let row):
            finish(row)
        case .failure:
            model.busy = false
            model.error = L("Capture failed")
        }
    }

    private func attemptTextSave() -> Result<RowItem, Error> {
        var payload = CapturePayload(rawText: trimmedText)
        payload.remindAt = model.remindOn ? model.remindAt : nil
        payload.remindHide = model.remindOn ? !model.keepVisible : nil
        return Result { try clients.createCapture(payload) }
    }

    private func finish(_ row: RowItem) {
        onSaved(row)
        model.resetAfterSave()
        dismiss()
    }

    private func close() {
        model.discardDraft()
        dismiss()
    }

    private func signIn() {
        model.prepareToDismiss()
        onRequestSignIn()
        dismiss()
    }

    private func readStableDirectMedia(_ file: CaptureDraftFile) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let accessing = file.url.startAccessingSecurityScopedResource()
            defer { if accessing { file.url.stopAccessingSecurityScopedResource() } }
            let stagedURL = try stageCaptureFile(
                at: file.url,
                expected: file.identity,
                maxBytes: directCaptureUploadMaxBytes
            )
            defer { removeStagedCaptureFile(stagedURL) }
            return try Data(contentsOf: stagedURL, options: .mappedIfSafe)
        }.value
    }

    private func stageStableFile(_ file: CaptureDraftFile) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let accessing = file.url.startAccessingSecurityScopedResource()
            defer { if accessing { file.url.stopAccessingSecurityScopedResource() } }
            return try stageCaptureFile(
                at: file.url,
                expected: file.identity,
                maxBytes: googleDriveUploadMaxBytes
            )
        }.value
    }

    private func completeTodoSuggestion() {
        model.text = CaptureTodoTag.completingSuggestion(in: model.text)
        model.focused = true
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            guard let data,
                  let url = URL(dataRepresentation: data, relativeTo: nil)
            else { return }
            Task { @MainActor in model.selectFile(url) }
        }
        return true
    }

    private func fileSubtitle(_ file: CaptureDraftFile) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(file.sizeBytes), countStyle: .file)
        let destination = file.kind == .directMedia ? L("Chronicle media") : "Google Drive"
        return "\(size) · \(destination)"
    }

    private func captureSheetError(_ error: Error) -> String {
        switch error {
        case CaptureClientError.requiresSignIn:
            L("Sign in to add files.")
        case GoogleDriveError.notConfigured:
            L("Google Drive is not configured for this app.")
        case CaptureMediaUploadError.fileTooLarge, GoogleDriveError.fileTooLarge:
            L("This file is too large.")
        case CaptureAudioRecorderError.permissionDenied:
            L("Microphone access is required to record audio.")
        default:
            L("We couldn't save this Capture. Try again.")
        }
    }
}

private struct CaptureSheetToolButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .padding(.horizontal, 9)
            .frame(minHeight: 30)
            .background(
                Color.primary.opacity(active ? 0.09 : configuration.isPressed ? 0.07 : 0.035),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
