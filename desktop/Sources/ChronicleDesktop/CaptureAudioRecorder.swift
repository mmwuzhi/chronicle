import AVFoundation
import Foundation

struct RecordedCaptureAudio: Equatable {
    let url: URL
    let durationSeconds: Int
}

@MainActor
final class CaptureAudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var recording = false
    @Published private(set) var seconds = 0
    var onMaximumDuration: ((RecordedCaptureAudio) -> Void)?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt: Date?
    private var outputURL: URL?
    private static let maximumSeconds = 5 * 60

    func start() async throws {
        guard !recording else { return }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw CaptureAudioRecorderError.permissionDenied }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chronicle-recording-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let next = try AVAudioRecorder(url: url, settings: settings)
        next.delegate = self
        next.prepareToRecord()
        guard next.record() else { throw CaptureAudioRecorderError.couldNotStart }
        recorder = next
        outputURL = url
        startedAt = Date()
        seconds = 0
        recording = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.recording else { return }
                self.seconds = min(Self.maximumSeconds, self.seconds + 1)
                if self.seconds >= Self.maximumSeconds {
                    if let completed = self.stop() {
                        self.onMaximumDuration?(completed)
                    }
                }
            }
        }
    }

    func stop() -> RecordedCaptureAudio? {
        guard recording, let outputURL else { return nil }
        let duration = max(1, min(Self.maximumSeconds, Int(Date().timeIntervalSince(startedAt ?? Date()))))
        recorder?.stop()
        finishState()
        return RecordedCaptureAudio(url: outputURL, durationSeconds: duration)
    }

    func cancel() {
        let url = outputURL
        recorder?.stop()
        finishState()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    private func finishState() {
        timer?.invalidate()
        timer = nil
        recorder = nil
        startedAt = nil
        outputURL = nil
        recording = false
        seconds = 0
    }
}

enum CaptureAudioRecorderError: Error, Equatable {
    case permissionDenied
    case couldNotStart
}
